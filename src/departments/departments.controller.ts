import {
  BadRequestException,
  Body,
  Controller,
  Get,
  Inject,
  NotFoundException,
  Param,
  Post,
  Put,
} from '@nestjs/common';
import { recordAudit } from '../audit/record-audit.js';
import { CurrentAuth, RequirePermissions } from '../auth/access.js';
import type { AuthContext } from '../auth/access.js';
import {
  integer,
  optionalInteger,
  readBody,
  text,
  unique,
  uuid,
} from '../common/input.js';
import type { Body as RequestBody } from '../common/input.js';
import { TenantDatabase } from '../database/tenant-database.js';

export const MAX_WAGE_CENTS = 100_000_000;

const departmentFields = {
  id: true,
  code: true,
  name: true,
  entryMinutes: true,
  exitMinutes: true,
  toleranceMinutes: true,
  workDays: true,
  dailyWageCents: true,
  isActive: true,
  _count: { select: { employees: true } },
} as const;

/** Código estable derivado del nombre: «Almacén Norte» → ALMACEN-NORTE. */
export function departmentCode(name: string): string {
  return name
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toUpperCase()
    .replace(/[^A-Z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40);
}

function readSchedule(body: RequestBody) {
  const name = text(body, 'name', 'El nombre del departamento', 80);
  if (name.length < 2) {
    throw new BadRequestException(
      'El nombre debe tener al menos 2 caracteres.',
    );
  }
  const code = departmentCode(name);
  if (!code) {
    throw new BadRequestException('El nombre debe incluir letras o números.');
  }
  const entryMinutes = integer(
    body,
    'entryMinutes',
    'La hora de entrada',
    0,
    1439,
  );
  const exitMinutes = integer(
    body,
    'exitMinutes',
    'La hora de salida',
    0,
    1439,
  );
  if (entryMinutes === exitMinutes) {
    throw new BadRequestException(
      'La entrada y la salida deben ser distintas.',
    );
  }
  return {
    name,
    code,
    entryMinutes,
    exitMinutes,
    toleranceMinutes: integer(
      body,
      'toleranceMinutes',
      'La tolerancia',
      0,
      240,
    ),
    workDays: integer(body, 'workDays', 'Los días laborables', 1, 127),
    dailyWageCents: optionalInteger(
      body,
      'dailyWageCents',
      'El salario diario',
      0,
      MAX_WAGE_CENTS,
    ),
  };
}

@Controller('departments')
export class DepartmentsController {
  constructor(@Inject(TenantDatabase) private readonly db: TenantDatabase) {}

  @RequirePermissions('departments.read')
  @Get()
  list(@CurrentAuth() auth: AuthContext) {
    return this.db.run(auth.companyId, (tx) =>
      tx.department.findMany({
        select: departmentFields,
        orderBy: { name: 'asc' },
      }),
    );
  }

  @RequirePermissions('departments.manage')
  @Post()
  create(@CurrentAuth() auth: AuthContext, @Body() raw: unknown) {
    const data = readSchedule(readBody(raw));
    return this.db.run(auth.companyId, async (tx) => {
      const department = await unique(
        tx.department.create({
          data: { ...data, companyId: auth.companyId },
          select: departmentFields,
        }),
        'Ya existe un departamento con ese nombre.',
      );
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'department.created',
        entityType: 'department',
        entityId: department.id,
        details: data,
      });
      return department;
    });
  }

  @RequirePermissions('departments.manage')
  @Put(':id')
  update(
    @CurrentAuth() auth: AuthContext,
    @Param('id') rawId: string,
    @Body() raw: unknown,
  ) {
    const id = uuid(rawId, 'El departamento');
    const data = readSchedule(readBody(raw));
    return this.db.run(auth.companyId, async (tx) => {
      if (!(await tx.department.findUnique({ where: { id } }))) {
        throw new NotFoundException('El departamento no existe.');
      }
      const department = await unique(
        tx.department.update({
          where: { id },
          data,
          select: departmentFields,
        }),
        'Ya existe un departamento con ese nombre.',
      );
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'department.updated',
        entityType: 'department',
        entityId: id,
        details: data,
      });
      return department;
    });
  }
}
