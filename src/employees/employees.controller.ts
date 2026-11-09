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
  Query,
} from '@nestjs/common';
import { recordAudit } from '../audit/record-audit.js';
import { CurrentAuth, RequirePermissions } from '../auth/access.js';
import type { AuthContext } from '../auth/access.js';
import {
  code,
  isoDate,
  optionalInteger,
  optionalText,
  optionalUuid,
  pageQuery,
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
  terminationEffectiveOn: true,
  terminationReason: true,
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

  /**
   * Lista paginada. Filtros: sucursal, departamento (`none` = sin
   * departamento), estado (`ACTIVE` por defecto, `TERMINATED` o `all`) y
   * búsqueda por nombre o número.
   */
  @RequirePermissions('employees.read')
  @Get()
  list(
    @CurrentAuth() auth: AuthContext,
    @Query('branchId') rawBranch?: string,
    @Query('departmentId') rawDepartment?: string,
    @Query('status') rawStatus?: string,
    @Query('q') rawQuery?: string,
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    const paging = pageQuery(page, pageSize);
    const branchId = optionalUuid(
      { branchId: rawBranch },
      'branchId',
      'La sucursal',
    );
    const withoutDepartment = rawDepartment === 'none';
    const departmentId = withoutDepartment
      ? null
      : optionalUuid(
          { departmentId: rawDepartment },
          'departmentId',
          'El departamento',
        );
    const status = rawStatus ?? 'ACTIVE';
    if (!['ACTIVE', 'TERMINATED', 'all'].includes(status)) {
      throw new BadRequestException(
        'El estado debe ser ACTIVE, TERMINATED o all.',
      );
    }
    const query = rawQuery?.trim().slice(0, 80) ?? '';
    const where: Prisma.EmployeeWhereInput = {
      ...(branchId ? { branchId } : {}),
      ...(withoutDepartment
        ? { departmentId: null }
        : departmentId
          ? { departmentId }
          : {}),
      ...(status === 'all'
        ? {}
        : { employmentStatus: status as 'ACTIVE' | 'TERMINATED' }),
      ...(query
        ? {
            OR: [
              { employeeNumber: { contains: query, mode: 'insensitive' } },
              { givenNames: { contains: query, mode: 'insensitive' } },
              { familyNames: { contains: query, mode: 'insensitive' } },
            ],
          }
        : {}),
    };
    return this.db.run(auth.companyId, async (tx) => {
      const total = await tx.employee.count({ where });
      const rows = await tx.employee.findMany({
        where,
        select: employeeFields,
        orderBy: [{ familyNames: 'asc' }, { givenNames: 'asc' }],
        skip: paging.skip,
        take: paging.pageSize,
      });
      return {
        items: rows.map(view),
        total,
        page: paging.page,
        pageSize: paging.pageSize,
      };
    });
  }

  @RequirePermissions('employees.read')
  @Get(':id')
  one(@CurrentAuth() auth: AuthContext, @Param('id') rawId: string) {
    const id = uuid(rawId, 'El empleado');
    return this.db.run(auth.companyId, async (tx) => {
      const employee = await tx.employee.findUnique({
        where: { id },
        select: employeeFields,
      });
      if (!employee) throw new NotFoundException('El empleado no existe.');
      return view(employee);
    });
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

  /**
   * Nombre, sucursal, departamento, salario, baja y reingreso. La baja exige
   * fecha efectiva y motivo; el reingreso (status ACTIVE) los limpia.
   */
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
      givenNames?: string;
      familyNames?: string;
      branchId?: string;
      departmentId?: string | null;
      dailyWageCents?: number | null;
      employmentStatus?: 'ACTIVE' | 'TERMINATED';
      terminationEffectiveOn?: Date | null;
      terminationReason?: string | null;
      terminationByAccountId?: string | null;
    } = {};
    if ('givenNames' in body) {
      data.givenNames = text(body, 'givenNames', 'El nombre', 160);
    }
    if ('familyNames' in body) {
      data.familyNames = text(body, 'familyNames', 'Los apellidos', 160);
    }
    if ('branchId' in body) {
      data.branchId = uuid(body.branchId, 'La sucursal');
    }
    if ('status' in body) {
      if (body.status === 'TERMINATED') {
        const reason = optionalText(
          body,
          'terminationReason',
          'El motivo de baja',
          500,
        );
        if (!reason || reason.length < 10) {
          throw new BadRequestException(
            'Escribe un motivo de baja de 10 a 500 caracteres.',
          );
        }
        data.employmentStatus = 'TERMINATED';
        data.terminationEffectiveOn = isoDate(
          body,
          'terminationEffectiveOn',
          'La fecha de baja',
        );
        data.terminationReason = reason;
        data.terminationByAccountId = auth.accountId;
      } else if (body.status === 'ACTIVE') {
        data.employmentStatus = 'ACTIVE';
        data.terminationEffectiveOn = null;
        data.terminationReason = null;
        data.terminationByAccountId = null;
      } else {
        throw new BadRequestException(
          'El estado debe ser ACTIVE o TERMINATED.',
        );
      }
    }
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
      if (
        data.branchId &&
        !(await tx.branch.findUnique({ where: { id: data.branchId } }))
      ) {
        throw new BadRequestException('La sucursal no existe.');
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
