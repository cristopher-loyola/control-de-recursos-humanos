import { Body, Controller, Get, Inject, Post } from '@nestjs/common';
import { recordAudit } from '../audit/record-audit.js';
import { CurrentAuth, RequirePermissions } from '../auth/access.js';
import type { AuthContext } from '../auth/access.js';
import { code, optionalText, readBody, text, unique } from '../common/input.js';
import { TenantDatabase } from '../database/tenant-database.js';

const branchFields = {
  id: true,
  code: true,
  name: true,
  timeZone: true,
  isActive: true,
} as const;

@Controller()
export class OrganizationController {
  constructor(@Inject(TenantDatabase) private readonly db: TenantDatabase) {}

  @RequirePermissions('company.read')
  @Get('company')
  company(@CurrentAuth() auth: AuthContext) {
    return this.db.run(auth.companyId, (tx) =>
      tx.company.findUniqueOrThrow({
        where: { id: auth.companyId },
        select: { id: true, name: true, slug: true, timeZone: true },
      }),
    );
  }

  @RequirePermissions('branches.read')
  @Get('branches')
  branches(@CurrentAuth() auth: AuthContext) {
    return this.db.run(auth.companyId, (tx) =>
      tx.branch.findMany({ select: branchFields, orderBy: { name: 'asc' } }),
    );
  }

  @RequirePermissions('branches.manage')
  @Post('branches')
  createBranch(@CurrentAuth() auth: AuthContext, @Body() raw: unknown) {
    const body = readBody(raw);
    const data = {
      companyId: auth.companyId,
      code: code(body, 'code', 'La clave de sucursal'),
      name: text(body, 'name', 'El nombre de la sucursal', 160),
      timeZone: optionalText(body, 'timeZone', 'La zona horaria', 80),
    };
    return this.db.run(auth.companyId, async (tx) => {
      const branch = await unique(
        tx.branch.create({ data, select: branchFields }),
        'Ya existe una sucursal con esa clave.',
      );
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'branch.created',
        entityType: 'branch',
        entityId: branch.id,
        details: { code: branch.code, name: branch.name },
      });
      return branch;
    });
  }
}
