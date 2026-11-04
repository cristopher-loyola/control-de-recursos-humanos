import {
  Body,
  Controller,
  Get,
  HttpCode,
  Inject,
  Post,
  Res,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import type { Response } from 'express';
import { TenantDatabase } from '../database/tenant-database.js';
import { email, readBody, secret, text } from '../common/input.js';
import { CurrentAuth, MfaStep, Public, RequirePermissions } from './access.js';
import type { AuthContext } from './access.js';
import {
  AuthService,
  MFA_WINDOW_MS,
  SESSION_LIFETIME_MS,
} from './auth.service.js';
import { clearSessionCookie, writeSessionCookie } from './session-token.js';

@Controller('auth')
export class AuthController {
  private readonly secureCookie: boolean;

  constructor(
    @Inject(AuthService) private readonly auth: AuthService,
    @Inject(TenantDatabase) private readonly db: TenantDatabase,
    @Inject(ConfigService) config: ConfigService,
  ) {
    this.secureCookie = config.getOrThrow<string>('NODE_ENV') === 'production';
  }

  @Public()
  @Post('login')
  @HttpCode(200)
  async login(
    @Body() raw: unknown,
    @Res({ passthrough: true }) response: Response,
  ) {
    const body = readBody(raw);
    const result = await this.auth.login(
      text(body, 'company', 'El código de empresa', 80).toLowerCase(),
      email(body, 'email'),
      secret(body, 'password', 'La contraseña'),
    );
    writeSessionCookie(
      response,
      result.token,
      this.secureCookie,
      MFA_WINDOW_MS,
    );
    return { nextStep: result.nextStep };
  }

  @MfaStep()
  @Post('mfa/setup')
  @HttpCode(200)
  setupMfa(@CurrentAuth() auth: AuthContext) {
    return this.auth.startMfaSetup(auth);
  }

  @MfaStep()
  @Post('mfa/verify')
  @HttpCode(200)
  async verifyMfa(
    @CurrentAuth() auth: AuthContext,
    @Body() raw: unknown,
    @Res({ passthrough: true }) response: Response,
  ) {
    const token = await this.auth.verifyMfa(
      auth,
      text(readBody(raw), 'code', 'El código', 6),
    );
    writeSessionCookie(response, token, this.secureCookie, SESSION_LIFETIME_MS);
    return { nextStep: 'DONE' };
  }

  @Post('logout')
  @HttpCode(204)
  async logout(
    @CurrentAuth() auth: AuthContext,
    @Res({ passthrough: true }) response: Response,
  ) {
    await this.auth.logout(auth);
    clearSessionCookie(response, this.secureCookie);
  }

  @RequirePermissions('self.read')
  @Get('me')
  me(@CurrentAuth() auth: AuthContext) {
    return this.db.run(auth.companyId, async (tx) => {
      const account = await tx.account.findUniqueOrThrow({
        where: {
          companyId_id: { companyId: auth.companyId, id: auth.accountId },
        },
        include: {
          company: { select: { name: true, slug: true } },
          employee: {
            select: {
              employeeNumber: true,
              givenNames: true,
              familyNames: true,
            },
          },
          roles: { include: { role: { select: { code: true, name: true } } } },
        },
      });
      return {
        id: account.id,
        email: account.email,
        company: account.company,
        employee: account.employee,
        roles: account.roles.map(({ role }) => role),
        permissions: [...auth.permissions].sort(),
      };
    });
  }
}
