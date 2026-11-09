import { Controller, Get, Inject, Query } from '@nestjs/common';
import { CurrentAuth, RequirePermissions } from '../auth/access.js';
import type { AuthContext } from '../auth/access.js';
import { isoDate, pageQuery } from '../common/input.js';
import { TenantDatabase } from '../database/tenant-database.js';
import type { Prisma } from '../generated/prisma/client.js';

@Controller('audit')
export class AuditController {
  constructor(@Inject(TenantDatabase) private readonly db: TenantDatabase) {}

  /**
   * Bitácora más reciente primero, paginada. Filtros: acción (prefijo, p. ej.
   * `employee.`), tipo de entidad y rango de fechas [from, to) en UTC.
   */
  @RequirePermissions('audit.read')
  @Get()
  list(
    @CurrentAuth() auth: AuthContext,
    @Query('action') action?: string,
    @Query('entityType') entityType?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    const paging = pageQuery(page, pageSize);
    const occurredAt: Prisma.DateTimeFilter = {};
    if (from) occurredAt.gte = isoDate({ from }, 'from', 'La fecha inicial');
    if (to) occurredAt.lt = isoDate({ to }, 'to', 'La fecha final');
    const where: Prisma.AuditEntryWhereInput = {
      ...(action ? { action: { startsWith: action.slice(0, 80) } } : {}),
      ...(entityType ? { entityType: entityType.slice(0, 80) } : {}),
      ...(from || to ? { occurredAt } : {}),
    };
    return this.db.run(auth.companyId, async (tx) => {
      const total = await tx.auditEntry.count({ where });
      const items = await tx.auditEntry.findMany({
        where,
        skip: paging.skip,
        take: paging.pageSize,
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
      });
      return { items, total, page: paging.page, pageSize: paging.pageSize };
    });
  }
}
