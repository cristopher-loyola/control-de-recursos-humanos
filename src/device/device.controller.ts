import {
  BadRequestException,
  Body,
  Controller,
  Get,
  HttpCode,
  Inject,
  Post,
  Req,
  Res,
  UnauthorizedException,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { recordAudit } from '../audit/record-audit.js';
import { CurrentDevice, DeviceRoute, Public } from '../auth/access.js';
import type { DeviceContext } from '../auth/access.js';
import { hashSessionToken, newSessionToken } from '../auth/session-token.js';
import { readBody, text, unique } from '../common/input.js';
import { TenantDatabase } from '../database/tenant-database.js';
import { hashActivationCode } from '../tablets/tablets.controller.js';
import { DeviceEvents, MAX_EVENTS_PER_BATCH } from './device-events.js';
import type { IncomingEvent } from './device-events.js';
import {
  DEVICE_KEY_ALGORITHM,
  readDevicePublicKey,
} from './device-signature.js';
import { DeviceSync } from './device-sync.js';

const INVALID_ACTIVATION = 'El código de vinculación no es válido o ya venció.';

@Controller('device')
export class DeviceController {
  constructor(
    @Inject(TenantDatabase) private readonly db: TenantDatabase,
    @Inject(DeviceSync) private readonly sync: DeviceSync,
    @Inject(DeviceEvents) private readonly events: DeviceEvents,
  ) {}

  /**
   * La tablet canjea el código de un solo uso por su token y registra la llave
   * pública con la que firmará cada checada. El token se entrega una sola vez.
   */
  @Public()
  @Post('activate')
  @HttpCode(200)
  async activate(@Body() raw: unknown) {
    const body = readBody(raw);
    const slug = text(
      body,
      'company',
      'El código de empresa',
      80,
    ).toLowerCase();
    const activationCode = text(body, 'code', 'El código de vinculación', 20);
    const key = readDevicePublicKey(body.publicKey);
    const companyId = await this.db.companyIdBySlug(slug);
    if (!companyId) throw new UnauthorizedException(INVALID_ACTIVATION);

    const now = new Date();
    const token = newSessionToken(companyId);
    const result = await this.db.run(companyId, async (tx) => {
      const activation = await tx.tabletActivation.findUnique({
        where: {
          companyId_codeHash: {
            companyId,
            codeHash: hashActivationCode(activationCode),
          },
        },
        include: { tablet: true },
      });
      if (
        !activation ||
        activation.usedAt ||
        activation.expiresAt <= now ||
        activation.tablet.status === 'REVOKED'
      ) {
        return null;
      }
      const tabletId = activation.tabletId;
      await tx.tabletActivation.update({
        where: { id: activation.id },
        data: { usedAt: now },
      });
      // Volver a vincular deja sin efecto la llave anterior.
      await tx.deviceKey.updateMany({
        where: { tabletId, revokedAt: null },
        data: { revokedAt: now },
      });
      // La tablet genera una llave nueva en cada vinculación; nunca se comparte.
      const deviceKey = await unique(
        tx.deviceKey.create({
          data: {
            companyId,
            tabletId,
            algorithm: DEVICE_KEY_ALGORITHM,
            publicKeyPem: key.pem,
            fingerprint: key.fingerprint,
          },
        }),
        'Esa llave ya se registró. Vuelve a intentar la vinculación.',
      );
      await tx.tablet.update({
        where: { id: tabletId },
        data: {
          status: 'ACTIVE',
          tokenHash: hashSessionToken(token),
          lastSeenAt: now,
        },
      });
      await recordAudit(tx, {
        companyId,
        actorAccountId: null,
        actorTabletId: tabletId,
        action: 'tablet.activated',
        entityType: 'tablet',
        entityId: tabletId,
        details: { deviceKeyId: deviceKey.id, keyFingerprint: key.fingerprint },
      });
      return tabletId;
    });
    if (!result) throw new UnauthorizedException(INVALID_ACTIVATION);
    return { token };
  }

  @DeviceRoute()
  @Get('sync')
  async snapshot(
    @CurrentDevice() device: DeviceContext,
    @Req() request: Request,
    @Res({ passthrough: true }) response: Response,
  ) {
    const body = await this.sync.snapshot(device);
    const etag = DeviceSync.etag(body);
    response.setHeader('ETag', etag);
    response.setHeader('Cache-Control', 'no-store');
    if (request.headers['if-none-match'] === etag) {
      response.status(304);
      return;
    }
    return body;
  }

  /** Logo de la empresa para el checador; la tablet lo guarda para verlo sin red. */
  @DeviceRoute()
  @Get('logo')
  logo(@CurrentDevice() device: DeviceContext) {
    return this.db.run(device.companyId, async (tx) => {
      const company = await tx.company.findUniqueOrThrow({
        where: { id: device.companyId },
        select: { logoMime: true, logoData: true, logoUpdatedAt: true },
      });
      return company.logoMime && company.logoData
        ? {
            mime: company.logoMime,
            data: Buffer.from(company.logoData).toString('base64'),
            updatedAt: company.logoUpdatedAt,
          }
        : { mime: null, data: null, updatedAt: company.logoUpdatedAt };
    });
  }

  @DeviceRoute()
  @Post('events')
  @HttpCode(200)
  async upload(@CurrentDevice() device: DeviceContext, @Body() raw: unknown) {
    const events = readBody(raw).events;
    if (
      !Array.isArray(events) ||
      events.length === 0 ||
      events.length > MAX_EVENTS_PER_BATCH
    ) {
      throw new BadRequestException(
        `Envía de 1 a ${MAX_EVENTS_PER_BATCH} checadas por lote.`,
      );
    }
    return {
      results: await this.events.ingest(device, events as IncomingEvent[]),
    };
  }
}
