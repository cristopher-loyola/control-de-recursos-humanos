import type { TenantTransaction } from '../database/tenant-database.js';
import type { Prisma } from '../generated/prisma/client.js';

export interface AuditInput {
  companyId: string;
  actorAccountId: string | null;
  /** Acción hecha por una tablet con su token de dispositivo. */
  actorTabletId?: string | null;
  action: string;
  entityType: string;
  entityId: string;
  details?: Prisma.InputJsonValue;
}

/** Se escribe en la misma transacción que el cambio; la API no puede editarla ni borrarla. */
export async function recordAudit(
  tx: TenantTransaction,
  entry: AuditInput,
): Promise<void> {
  await tx.auditEntry.create({
    data: {
      companyId: entry.companyId,
      actorType: entry.actorAccountId
        ? 'ACCOUNT'
        : entry.actorTabletId
          ? 'TABLET'
          : 'SYSTEM',
      actorAccountId: entry.actorAccountId,
      actorTabletId: entry.actorTabletId ?? null,
      action: entry.action,
      entityType: entry.entityType,
      entityId: entry.entityId,
      details: entry.details,
    },
  });
}
