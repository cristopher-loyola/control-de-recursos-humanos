import { Inject, Injectable } from '@nestjs/common';
import { TenantDatabase } from '../database/tenant-database.js';
import type { DeviceContext } from './access.js';
import { companyOfToken, hashSessionToken } from './session-token.js';

const TOUCH_INTERVAL_MS = 60_000;

/**
 * Token de tablet: mismo formato que la sesión (`empresa.secreto`), con su hash
 * en `tablets.token_hash`. Revocar la tablet o su llave lo invalida.
 */
@Injectable()
export class DeviceAuth {
  constructor(@Inject(TenantDatabase) private readonly db: TenantDatabase) {}

  async resolve(token: string | null): Promise<DeviceContext | null> {
    const companyId = token ? companyOfToken(token) : null;
    if (!token || !companyId) return null;
    const now = new Date();
    return this.db.run(companyId, async (tx) => {
      const tablet = await tx.tablet.findUnique({
        where: { tokenHash: hashSessionToken(token) },
        include: {
          company: { select: { isActive: true } },
          keys: { where: { revokedAt: null }, take: 1 },
        },
      });
      const key = tablet?.keys[0];
      if (
        !tablet ||
        tablet.status !== 'ACTIVE' ||
        !tablet.company.isActive ||
        !key
      ) {
        return null;
      }
      if (
        !tablet.lastSeenAt ||
        now.getTime() - tablet.lastSeenAt.getTime() > TOUCH_INTERVAL_MS
      ) {
        await tx.tablet.update({
          where: { id: tablet.id },
          data: { lastSeenAt: now },
        });
      }
      return {
        companyId,
        tabletId: tablet.id,
        branchId: tablet.branchId,
        deviceKeyId: key.id,
        publicKeyPem: key.publicKeyPem,
      };
    });
  }
}
