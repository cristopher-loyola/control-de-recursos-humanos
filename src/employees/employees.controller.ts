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
  isoDate,
  optionalInteger,
  optionalUuid,
  readBody,
  text,
  unique,
  uuid,
} from '../common/input.js';
import { MAX_WAGE_CENTS } from '../departments/departments.controller.js';
import { TenantDatabase } from '../database/tenant-database.js';
import type { TenantTransaction } from '../database/tenant-database.js';
import type { Prisma } from '../generated/prisma/client.js';

const employeeFields = {
  id: true,
  employeeNumber: true,
  givenNames: true,
  familyNames: true,
  hiredOn: true,
  employmentStatus: true,
  dailyWageCents: true,
  branch: { select: { id: true, code: true, name: true } },
  department: { select: { id: true, name: true } },
  biometricConsents: {
    where: { revokedAt: null },
    take: 1,
    select: { id: true, signedDocumentObjectKey: true, grantedAt: true },
  },
  faceTemplates: { where: { revokedAt: null }, take: 1, select: { id: true } },
  pin: { select: { updatedAt: true } },
} as const;

type EmployeeRow = Prisma.EmployeeGetPayload<{ select: typeof employeeFields }>;

function view(row: EmployeeRow) {
  const { biometricConsents, faceTemplates, pin, ...rest } = row;
  const consent = biometricConsents[0];
  return {
    ...rest,
    consent: consent
      ? {
          id: consent.id,
          documentReference: consent.signedDocumentObjectKey,
          grantedAt: consent.grantedAt,
        }
      : null,
    hasFace: faceTemplates.length > 0,
    hasPin: pin !== null,
  };
}

/** Siguiente número consecutivo entre los números puramente numéricos. */
async function nextEmployeeNumber(tx: TenantTransaction): Promise<string> {
  const rows = await tx.$queryRaw<{ next: bigint | null }[]>`
    SELECT MAX(employee_number::bigint) + 1 AS next
    FROM employees WHERE employee_number ~ '^[0-9]{1,18}$'`;
  return String(rows[0]?.next ?? 1n);
}

@Controller('employees')
export class EmployeesController {
  constructor(@Inject(TenantDatabase) private readonly db: TenantDatabase) {}

  @RequirePermissions('employees.read')
  @Get()
  list(@CurrentAuth() auth: AuthContext) {
    return this.db.run(auth.companyId, async (tx) =>
      (
        await tx.employee.findMany({
          select: employeeFields,
          orderBy: [{ familyNames: 'asc' }, { givenNames: 'asc' }],
        })
      ).map(view),
    );
  }

  @RequirePermissions('employees.manage')
  @Post()
  create(@CurrentAuth() auth: AuthContext, @Body() raw: unknown) {
    const body = readBody(raw);
    const branchId = uuid(body.branchId, 'La sucursal');
    const departmentId = optionalUuid(body, 'departmentId', 'El departamento');
    const requestedNumber =
      body.employeeNumber === undefined ||
      body.employeeNumber === null ||
      body.employeeNumber === ''
        ? null
        : code(body, 'employeeNumber', 'El número de empleado');
    const data = {
      companyId: auth.companyId,
      branchId,
      departmentId,
      givenNames: text(body, 'givenNames', 'El nombre', 160),
      familyNames: text(body, 'familyNames', 'Los apellidos', 160),
      hiredOn:
        body.hiredOn === undefined
          ? new Date(new Date().toISOString().slice(0, 10))
          : isoDate(body, 'hiredOn', 'La fecha de ingreso'),
      dailyWageCents: optionalInteger(
        body,
        'dailyWageCents',
        'El salario diario',
        0,
        MAX_WAGE_CENTS,
      ),
    };
    return this.db.run(auth.companyId, async (tx) => {
      if (!(await tx.branch.findUnique({ where: { id: branchId } }))) {
        throw new BadRequestException('La sucursal no existe.');
      }
      if (
        departmentId &&
        !(await tx.department.findUnique({ where: { id: departmentId } }))
      ) {
        throw new BadRequestException('El departamento no existe.');
      }
      const employeeNumber = requestedNumber ?? (await nextEmployeeNumber(tx));
      const employee = await unique(
        tx.employee.create({
          data: { ...data, employeeNumber },
          select: employeeFields,
        }),
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
      return view(employee);
    });
  }

  /** Departamento y salario diario; los demás datos no cambian desde la tablet. */
  @RequirePermissions('employees.manage')
  @Patch(':id')
  update(
    @CurrentAuth() auth: AuthContext,
    @Param('id') rawId: string,
    @Body() raw: unknown,
  ) {
    const id = uuid(rawId, 'El empleado');
    const body = readBody(raw);
    const data: {
      departmentId?: string | null;
      dailyWageCents?: number | null;
    } = {};
    if ('departmentId' in body) {
      data.departmentId = optionalUuid(body, 'departmentId', 'El departamento');
    }
    if ('dailyWageCents' in body) {
      data.dailyWageCents = optionalInteger(
        body,
        'dailyWageCents',
        'El salario diario',
        0,
        MAX_WAGE_CENTS,
      );
    }
    if (Object.keys(data).length === 0) {
      throw new BadRequestException('No hay cambios que guardar.');
    }
    return this.db.run(auth.companyId, async (tx) => {
      if (!(await tx.employee.findUnique({ where: { id } }))) {
        throw new NotFoundException('El empleado no existe.');
      }
      if (
        data.departmentId &&
        !(await tx.department.findUnique({ where: { id: data.departmentId } }))
      ) {
        throw new BadRequestException('El departamento no existe.');
      }
      const employee = await tx.employee.update({
        where: { id },
        data,
        select: employeeFields,
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'employee.updated',
        entityType: 'employee',
        entityId: id,
        details: data,
      });
      return view(employee);
    });
  }
}
