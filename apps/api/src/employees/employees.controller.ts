import {
  BadRequestException,
  Body,
  Controller,
  Get,
  Inject,
  Post,
} from '@nestjs/common';
import { recordAudit } from '../audit/record-audit.js';
import { CurrentAuth, RequirePermissions } from '../auth/access.js';
import type { AuthContext } from '../auth/access.js';
import {
  code,
  isoDate,
  readBody,
  text,
  unique,
  uuid,
} from '../common/input.js';
import { TenantDatabase } from '../database/tenant-database.js';

const employeeFields = {
  id: true,
  employeeNumber: true,
  givenNames: true,
  familyNames: true,
  hiredOn: true,
  employmentStatus: true,
  branch: { select: { id: true, code: true, name: true } },
} as const;

@Controller('employees')
export class EmployeesController {
  constructor(@Inject(TenantDatabase) private readonly db: TenantDatabase) {}

  @RequirePermissions('employees.read')
  @Get()
  list(@CurrentAuth() auth: AuthContext) {
    return this.db.run(auth.companyId, (tx) =>
      tx.employee.findMany({
        select: employeeFields,
        orderBy: [{ familyNames: 'asc' }, { givenNames: 'asc' }],
      }),
    );
  }

  @RequirePermissions('employees.manage')
  @Post()
  create(@CurrentAuth() auth: AuthContext, @Body() raw: unknown) {
    const body = readBody(raw);
    const branchId = uuid(body.branchId, 'La sucursal');
    const data = {
      companyId: auth.companyId,
      branchId,
      employeeNumber: code(body, 'employeeNumber', 'El número de empleado'),
      givenNames: text(body, 'givenNames', 'El nombre', 160),
      familyNames: text(body, 'familyNames', 'Los apellidos', 160),
      hiredOn: isoDate(body, 'hiredOn', 'La fecha de ingreso'),
    };
    return this.db.run(auth.companyId, async (tx) => {
      if (!(await tx.branch.findUnique({ where: { id: branchId } }))) {
        throw new BadRequestException('La sucursal no existe.');
      }
      const employee = await unique(
        tx.employee.create({ data, select: employeeFields }),
        'Ya existe un empleado con ese número.',
      );
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'employee.created',
        entityType: 'employee',
        entityId: employee.id,
        details: { employeeNumber: employee.employeeNumber },
      });
      return employee;
    });
  }
}
