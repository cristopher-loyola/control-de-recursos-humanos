import { randomInt } from 'node:crypto';
import {
  BadRequestException,
  Body,
  Controller,
  Get,
  HttpCode,
  Inject,
  NotFoundException,
  Param,
  Patch,
  Post,
  Req,
} from '@nestjs/common';
import type { Request } from 'express';
import { recordAudit } from '../audit/record-audit.js';
import { CurrentAuth, RequirePermissions } from '../auth/access.js';
import type { AuthContext } from '../auth/access.js';
import { hashSessionToken } from '../auth/session-token.js';
import {
  code,
  optionalText,
  optionalUuid,
  readBody,
  text,
  unique,
  uuid,
} from '../common/input.js';
import { TenantDatabase } from '../database/tenant-database.js';
import {
  ServerIdentity,
  linkQr,
  shortFingerprint,
} from '../server-identity.js';

export const ACTIVATION_LIFETIME_MS = 15 * 60_000;
/** Nombre de una tablet recién creada, hasta que se le pone su ubicación. */
export const NO_LOCATION = 'Sin ubicación';
// Sin 0/O, 1/I/L: se dicta y se escribe a mano en la tablet.
const ACTIVATION_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

export function newActivationCode(): string {
  return Array.from(
    { length: 8 },
    () => ACTIVATION_ALPHABET[randomInt(ACTIVATION_ALPHABET.length)],
  ).join('');
}

/** El código se compara sin importar espacios, guiones ni mayúsculas. */
export function normalizeActivationCode(value: string): string {
  return value.replace(/[\s-]/g, '').toUpperCase();
}

export function hashActivationCode(value: string): string {
  return hashSessionToken(
    `tablet-activation:${normalizeActivationCode(value)}`,
  );
}

const tabletFields = {
  id: true,
  code: true,
  name: true,
  status: true,
  lastSeenAt: true,
  lastSynchronizedAt: true,
  createdAt: true,
  branch: { select: { id: true, code: true, name: true } },
} as const;

@Controller('tablets')
export class TabletsController {
  constructor(
    @Inject(TenantDatabase) private readonly db: TenantDatabase,
    @Inject(ServerIdentity) private readonly identity: ServerIdentity,
  ) {}

  @RequirePermissions('tablets.read')
  @Get()
  list(@CurrentAuth() auth: AuthContext) {
    return this.db.run(auth.companyId, (tx) =>
      tx.tablet.findMany({ select: tabletFields, orderBy: { name: 'asc' } }),
    );
  }

  @RequirePermissions('tablets.manage')
  @Post()
  create(@CurrentAuth() auth: AuthContext, @Body() raw: unknown) {
    const body = readBody(raw);
    const branchId = uuid(body.branchId, 'La sucursal');
    const data = {
      companyId: auth.companyId,
      branchId,
      // La ubicación se puede poner después de vincularla.
      name:
        optionalText(body, 'name', 'La ubicación de la tablet', 160) ??
        NO_LOCATION,
    };
    // Sin clave se asigna la siguiente libre: TAB-1, TAB-2…
    const given =
      typeof body.code === 'string' && body.code.trim() !== ''
        ? code(body, 'code', 'El código de la tablet')
        : null;
    return this.db.run(auth.companyId, async (tx) => {
      if (!(await tx.branch.findUnique({ where: { id: branchId } }))) {
        throw new BadRequestException('La sucursal no existe.');
      }
      let tabletCode = given;
      if (!tabletCode) {
        const used = new Set(
          (await tx.tablet.findMany({ select: { code: true } })).map((t) =>
            t.code.toUpperCase(),
          ),
        );
        let next = used.size + 1;
        while (used.has(`TAB-${next}`)) next++;
        tabletCode = `TAB-${next}`;
      }
      const tablet = await unique(
        tx.tablet.create({
          data: { ...data, code: tabletCode },
          select: tabletFields,
        }),
        'Ya existe una tablet con ese código.',
      );
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'tablet.created',
        entityType: 'tablet',
        entityId: tablet.id,
        details: { code: tablet.code, branchId },
      });
      return tablet;
    });
  }

  /** Cambia la ubicación (nombre) o la sucursal de la tablet. */
  @RequirePermissions('tablets.manage')
  @Patch(':id')
  update(
    @CurrentAuth() auth: AuthContext,
    @Param('id') rawId: string,
    @Body() raw: unknown,
  ) {
    const id = uuid(rawId, 'La tablet');
    const body = readBody(raw);
    const name =
      body.name === undefined
        ? undefined
        : text(body, 'name', 'La ubicación de la tablet', 160);
    const branchId = optionalUuid(body, 'branchId', 'La sucursal') ?? undefined;
    if (name === undefined && branchId === undefined) {
      throw new BadRequestException('No hay cambios.');
    }
    return this.db.run(auth.companyId, async (tx) => {
      const current = await tx.tablet.findUnique({ where: { id } });
      if (!current) throw new NotFoundException('La tablet no existe.');
      if (branchId) {
        const branch = await tx.branch.findUnique({ where: { id: branchId } });
        if (!branch?.isActive)
          throw new BadRequestException('La sucursal no existe.');
      }
      const tablet = await tx.tablet.update({
        where: { id },
        data: { name, branchId },
        select: tabletFields,
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'tablet.updated',
        entityType: 'tablet',
        entityId: id,
        details: {
          ...(name !== undefined ? { from: current.name, to: name } : {}),
          ...(branchId ? { branchId } : {}),
        },
      });
      return tablet;
    });
  }

  /**
   * Código de un solo uso, válido 15 minutos. Se muestra una vez; volver a
   * vincular una tablet activa le asigna token y llave nuevos.
   */
  @RequirePermissions('tablets.manage')
  @Post(':id/activation')
  @HttpCode(200)
  async activation(
    @CurrentAuth() auth: AuthContext,
    @Param('id') rawId: string,
    @Req() request: Request,
  ) {
    const id = uuid(rawId, 'La tablet');
    const endpoint = await this.identity.deviceEndpoint(request.headers.host);
    const activationCode = newActivationCode();
    const expiresAt = new Date(Date.now() + ACTIVATION_LIFETIME_MS);
    return this.db.run(auth.companyId, async (tx) => {
      const tablet = await tx.tablet.findUnique({
        where: { id },
        include: { company: { select: { slug: true } } },
      });
      if (!tablet) throw new NotFoundException('La tablet no existe.');
      if (tablet.status === 'REVOKED') {
        throw new BadRequestException(
          'La tablet fue revocada. Da de alta otra con un código nuevo.',
        );
      }
      // Solo vale el último código generado para esta tablet.
      await tx.tabletActivation.updateMany({
        where: { tabletId: id, usedAt: null },
        data: { usedAt: new Date() },
      });
      await tx.tabletActivation.create({
        data: {
          companyId: auth.companyId,
          tabletId: id,
          codeHash: hashActivationCode(activationCode),
          createdByAccountId: auth.accountId,
          expiresAt,
        },
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'tablet.activation_issued',
        entityType: 'tablet',
        entityId: id,
      });
      const shown = `${activationCode.slice(0, 4)}-${activationCode.slice(4)}`;
      return {
        company: tablet.company.slug,
        code: shown,
        expiresAt,
        serverFingerprint: endpoint
          ? shortFingerprint(endpoint.fingerprint)
          : this.identity.shortFingerprint,
        // Con el QR la tablet se vincula sola; sin él, se escribe el código.
        serverUrl: endpoint?.serverUrl ?? null,
        qr: endpoint ? linkQr(endpoint, tablet.company.slug, shown) : null,
      };
    });
  }

  @RequirePermissions('tablets.manage')
  @Post(':id/revoke')
  @HttpCode(200)
  revoke(@CurrentAuth() auth: AuthContext, @Param('id') rawId: string) {
    const id = uuid(rawId, 'La tablet');
    return this.db.run(auth.companyId, async (tx) => {
      const tablet = await tx.tablet.findUnique({ where: { id } });
      if (!tablet) throw new NotFoundException('La tablet no existe.');
      const now = new Date();
      await tx.tablet.update({
        where: { id },
        data: { status: 'REVOKED', tokenHash: null },
      });
      await tx.deviceKey.updateMany({
        where: { tabletId: id, revokedAt: null },
        data: { revokedAt: now },
      });
      await tx.tabletActivation.updateMany({
        where: { tabletId: id, usedAt: null },
        data: { usedAt: now },
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'tablet.revoked',
        entityType: 'tablet',
        entityId: id,
      });
      return tx.tablet.findUniqueOrThrow({
        where: { id },
        select: tabletFields,
      });
    });
  }
}
