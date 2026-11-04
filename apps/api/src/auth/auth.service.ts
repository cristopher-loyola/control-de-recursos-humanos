import {
  ForbiddenException,
  HttpException,
  HttpStatus,
  Inject,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { recordAudit } from '../audit/record-audit.js';
import { TenantDatabase } from '../database/tenant-database.js';
import type { TenantTransaction } from '../database/tenant-database.js';
import type { AuthContext } from './access.js';
import { spendPasswordCheck, verifyPassword } from './passwords.js';
import { SecretBox } from './secret-box.js';
import {
  companyOfToken,
  hashSessionToken,
  newSessionToken,
} from './session-token.js';
import { base32, matchTotp, newTotpSecret, otpauthUri } from './totp.js';

export const MFA_WINDOW_MS = 5 * 60_000;
export const IDLE_TIMEOUT_MS = 30 * 60_000;
export const SESSION_LIFETIME_MS = 12 * 60 * 60_000;
export const MAX_FAILED_LOGINS = 5;
export const LOCKOUT_MS = 15 * 60_000;
const MAX_FAILED_MFA = 5;
const TOUCH_INTERVAL_MS = 60_000;
const ISSUER = 'Control de RH';

const INVALID_LOGIN = 'Empresa, correo o contraseña incorrectos.';

export interface LoginResult {
  token: string;
  nextStep: 'MFA_SETUP' | 'MFA_CODE';
}

type LoginOutcome =
  { kind: 'ok'; result: LoginResult } | { kind: 'locked' | 'invalid' };

@Injectable()
export class AuthService {
  private readonly box: SecretBox;

  constructor(
    @Inject(TenantDatabase) private readonly db: TenantDatabase,
    @Inject(ConfigService) config: ConfigService,
  ) {
    this.box = new SecretBox(config.getOrThrow<string>('TOTP_ENCRYPTION_KEY'));
  }

  async login(
    companySlug: string,
    email: string,
    password: string,
  ): Promise<LoginResult> {
    const companyId = await this.db.companyIdBySlug(companySlug);
    if (!companyId) {
      await spendPasswordCheck(password);
      throw new UnauthorizedException(INVALID_LOGIN);
    }

    const now = new Date();
    // Los fallos se registran y confirman antes de responder; lanzar dentro de la transacción los desharía.
    const outcome = await this.db.run<LoginOutcome>(companyId, async (tx) => {
      const account = await tx.account.findUnique({
        where: { companyId_email: { companyId, email } },
      });
      if (!account) {
        await spendPasswordCheck(password);
        return { kind: 'invalid' };
      }
      if (account.lockedUntil && account.lockedUntil > now) {
        return { kind: 'locked' };
      }
      if (!(await verifyPassword(password, account.passwordHash))) {
        const failures = account.failedLoginCount + 1;
        const locked = failures >= MAX_FAILED_LOGINS;
        await tx.account.update({
          where: { id: account.id },
          data: {
            failedLoginCount: locked ? 0 : failures,
            lockedUntil: locked
              ? new Date(now.getTime() + LOCKOUT_MS)
              : account.lockedUntil,
          },
        });
        await recordAudit(tx, {
          companyId,
          actorAccountId: account.id,
          action: locked ? 'auth.locked' : 'auth.login_failed',
          entityType: 'account',
          entityId: account.id,
        });
        return { kind: locked ? 'locked' : 'invalid' };
      }
      if (account.status !== 'ACTIVE') {
        return { kind: 'invalid' };
      }

      await tx.account.update({
        where: { id: account.id },
        data: { failedLoginCount: 0, lockedUntil: null },
      });
      const token = newSessionToken(companyId);
      await tx.session.create({
        data: {
          companyId,
          accountId: account.id,
          tokenHash: hashSessionToken(token),
          stage: 'MFA_PENDING',
          expiresAt: new Date(now.getTime() + MFA_WINDOW_MS),
        },
      });
      return {
        kind: 'ok',
        result: {
          token,
          nextStep: account.totpEnabledAt ? 'MFA_CODE' : 'MFA_SETUP',
        },
      };
    });

    if (outcome.kind === 'locked') {
      throw new HttpException(
        'Demasiados intentos. La cuenta quedó bloqueada 15 minutos.',
        HttpStatus.TOO_MANY_REQUESTS,
      );
    }
    if (outcome.kind !== 'ok') {
      throw new UnauthorizedException(INVALID_LOGIN);
    }
    return outcome.result;
  }

  /** Genera el secreto mientras el doble factor no esté activado. Cada llamada lo reemplaza. */
  async startMfaSetup(
    auth: AuthContext,
  ): Promise<{ secret: string; uri: string }> {
    return this.db.run(auth.companyId, async (tx) => {
      const account = await this.account(tx, auth);
      if (account.totpEnabledAt) {
        throw new ForbiddenException('El doble factor ya está configurado.');
      }
      const secret = newTotpSecret();
      await tx.account.update({
        where: { id: account.id },
        data: {
          totpSecret: this.box.seal(secret, this.totpContext(account.id)),
          totpLastStep: null,
        },
      });
      const company = await tx.company.findUniqueOrThrow({
        where: { id: auth.companyId },
      });
      return {
        secret: base32(secret),
        uri: otpauthUri(secret, `${account.email} (${company.slug})`, ISSUER),
      };
    });
  }

  /** Verifica el código, activa el doble factor si hacía falta y emite un token nuevo. */
  async verifyMfa(auth: AuthContext, code: string): Promise<string> {
    const now = new Date();
    const outcome = await this.db.run(auth.companyId, async (tx) => {
      const account = await this.account(tx, auth);
      const step = account.totpSecret
        ? matchTotp(
            this.box.open(account.totpSecret, this.totpContext(account.id)),
            code,
            now,
            account.totpLastStep,
          )
        : null;

      if (step === null) {
        const session = await tx.session.update({
          where: { id: auth.sessionId },
          data: { mfaFailedCount: { increment: 1 } },
        });
        if (session.mfaFailedCount >= MAX_FAILED_MFA) {
          await tx.session.update({
            where: { id: auth.sessionId },
            data: { revokedAt: now },
          });
        }
        await recordAudit(tx, {
          companyId: auth.companyId,
          actorAccountId: account.id,
          action: 'auth.mfa_failed',
          entityType: 'account',
          entityId: account.id,
        });
        return null;
      }

      const enabling = !account.totpEnabledAt;
      await tx.account.update({
        where: { id: account.id },
        data: {
          totpLastStep: BigInt(step),
          totpEnabledAt: account.totpEnabledAt ?? now,
          lastLoginAt: now,
        },
      });
      await tx.session.update({
        where: { id: auth.sessionId },
        data: { revokedAt: now },
      });
      const token = newSessionToken(auth.companyId);
      await tx.session.create({
        data: {
          companyId: auth.companyId,
          accountId: account.id,
          tokenHash: hashSessionToken(token),
          stage: 'ACTIVE',
          expiresAt: new Date(now.getTime() + SESSION_LIFETIME_MS),
        },
      });
      if (enabling) {
        await recordAudit(tx, {
          companyId: auth.companyId,
          actorAccountId: account.id,
          action: 'auth.mfa_enabled',
          entityType: 'account',
          entityId: account.id,
        });
      }
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: account.id,
        action: 'auth.login',
        entityType: 'account',
        entityId: account.id,
      });
      return token;
    });

    if (!outcome) {
      throw new UnauthorizedException('El código no es válido o ya se usó.');
    }
    return outcome;
  }

  async logout(auth: AuthContext): Promise<void> {
    await this.db.run(auth.companyId, (tx) =>
      tx.session.update({
        where: { id: auth.sessionId },
        data: { revokedAt: new Date() },
      }),
    );
  }

  /** Devuelve null ante cualquier token inválido, vencido o revocado. */
  async resolve(token: string | null): Promise<AuthContext | null> {
    const companyId = token ? companyOfToken(token) : null;
    if (!token || !companyId) {
      return null;
    }
    const now = new Date();
    return this.db.run(companyId, async (tx) => {
      const session = await tx.session.findUnique({
        where: { tokenHash: hashSessionToken(token) },
        include: { account: true, company: true },
      });
      if (
        !session ||
        session.revokedAt ||
        session.expiresAt <= now ||
        !session.company.isActive ||
        session.account.status !== 'ACTIVE' ||
        (session.stage === 'ACTIVE' &&
          now.getTime() - session.lastSeenAt.getTime() > IDLE_TIMEOUT_MS)
      ) {
        return null;
      }
      if (now.getTime() - session.lastSeenAt.getTime() > TOUCH_INTERVAL_MS) {
        await tx.session.update({
          where: { id: session.id },
          data: { lastSeenAt: now },
        });
      }
      const permissions = await tx.permission.findMany({
        where: {
          roles: {
            some: {
              companyId,
              role: { accounts: { some: { accountId: session.accountId } } },
            },
          },
        },
        select: { code: true },
      });
      return {
        sessionId: session.id,
        companyId,
        accountId: session.accountId,
        stage: session.stage,
        permissions: new Set(permissions.map((permission) => permission.code)),
      };
    });
  }

  private async account(tx: TenantTransaction, auth: AuthContext) {
    return tx.account.findUniqueOrThrow({
      where: {
        companyId_id: { companyId: auth.companyId, id: auth.accountId },
      },
    });
  }

  private totpContext(accountId: string): string {
    return `accesos.totp.v1:${accountId}`;
  }
}
