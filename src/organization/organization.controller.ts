import {
  BadRequestException,
  Body,
  Controller,
  Get,
  Inject,
  NotFoundException,
  Param,
  Patch,
  Post,
} from '@nestjs/common';
import { recordAudit } from '../audit/record-audit.js';
import { CurrentAuth, RequirePermissions } from '../auth/access.js';
import type { AuthContext } from '../auth/access.js';
import {
  code,
  optionalText,
  readBody,
  text,
  unique,
  uuid,
} from '../common/input.js';
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

  /** Nombre, zona horaria y si está activa; la clave no cambia. */
  @RequirePermissions('branches.manage')
  @Patch('branches/:id')
  updateBranch(
    @CurrentAuth() auth: AuthContext,
    @Param('id') rawId: string,
    @Body() raw: unknown,
  ) {
    const id = uuid(rawId, 'La sucursal');
    const body = readBody(raw);
    const data: {
      name?: string;
      timeZone?: string | null;
      isActive?: boolean;
    } = {};
    if ('name' in body) {
      data.name = text(body, 'name', 'El nombre de la sucursal', 160);
    }
    if ('timeZone' in body) {
      data.timeZone = optionalText(body, 'timeZone', 'La zona horaria', 80);
    }
    if ('isActive' in body) {
      if (typeof body.isActive !== 'boolean') {
        throw new BadRequestException('isActive debe ser true o false.');
      }
      data.isActive = body.isActive;
    }
    if (Object.keys(data).length === 0) {
      throw new BadRequestException('No hay cambios que guardar.');
    }
    return this.db.run(auth.companyId, async (tx) => {
      if (!(await tx.branch.findUnique({ where: { id } }))) {
        throw new NotFoundException('La sucursal no existe.');
      }
      if (data.isActive === false) {
        const people = await tx.employee.count({
          where: { branchId: id, employmentStatus: 'ACTIVE' },
        });
        if (people > 0) {
          throw new BadRequestException(
            'La sucursal tiene empleados activos; muévelos antes de desactivarla.',
          );
        }
      }
      const branch = await tx.branch.update({
        where: { id },
        data,
        select: branchFields,
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'branch.updated',
        entityType: 'branch',
        entityId: id,
        details: data,
      });
      return branch;
    });
  }
}
