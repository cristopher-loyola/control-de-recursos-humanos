import { Controller, Get, Inject } from '@nestjs/common';
import { CurrentAuth, RequirePermissions } from '../auth/access.js';
import type { AuthContext } from '../auth/access.js';
import { TenantDatabase } from '../database/tenant-database.js';

@Controller('audit')
export class AuditController {
  constructor(@Inject(TenantDatabase) private readonly db: TenantDatabase) {}

  @RequirePermissions('audit.read')
  @Get()
  list(@CurrentAuth() auth: AuthContext) {
    return this.db.run(auth.companyId, (tx) =>
      tx.auditEntry.findMany({
        take: 200,
        orderBy: { occurredAt: 'desc' },
        select: {
          id: true,
          action: true,
          entityType: true,
          entityId: true,
          details: true,
          occurredAt: true,
          actorType: true,
          actorAccount: { select: { email: true } },
        },
      }),
    );
  }
}
