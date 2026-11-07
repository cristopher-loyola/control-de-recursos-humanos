import {
  BadRequestException,
  Body,
  Controller,
  Get,
  Inject,
  NotFoundException,
  Param,
  Put,
  Query,
} from '@nestjs/common';
import { recordAudit } from '../audit/record-audit.js';
import { reviewStatus } from '../attendance/review-status.js';
import { localTime } from '../attendance/schedule.js';
import { CurrentAuth, RequirePermissions } from '../auth/access.js';
import type { AuthContext } from '../auth/access.js';
import {
  integer,
  isoDate,
  optionalUuid,
  readBody,
  uuid,
} from '../common/input.js';
import { TenantDatabase } from '../database/tenant-database.js';
import type { TenantTransaction } from '../database/tenant-database.js';
import {
  addDays,
  bradford,
  bradfordLight,
  computeKpis,
  periodFor,
  previousPeriod,
  rateLight,
} from './kpi-engine.js';
import type {
  KpiContext,
  KpiEmployeeInput,
  KpiTargets,
  Period,
  PeriodKind,
} from './kpi-engine.js';

export const DEFAULT_TARGETS: KpiTargets = {
  attendanceMin: 95,
  punctualityMin: 90,
  bradfordWarning: 51,
  bradfordAlert: 201,
};

const SERIES_LENGTH = 6;

function readPeriod(
  kind: string | undefined,
  anchor: string | undefined,
  today: string,
): Period {
  const value = kind ?? 'month';
  if (!['week', 'month', 'quarter'].includes(value)) {
    throw new BadRequestException('El periodo debe ser week, month o quarter.');
  }
  const day = anchor
    ? isoDate({ anchor }, 'anchor', 'La fecha').toISOString().slice(0, 10)
    : today;
  return periodFor(value as PeriodKind, day);
}

interface Loaded {
  context: KpiContext;
  targets: KpiTargets;
  employees: {
    id: string;
    employeeNumber: string;
    name: string;
    department: { id: string; name: string } | null;
    input: KpiEmployeeInput;
  }[];
}

/** Trae todo lo necesario en pocas consultas y calcula en memoria. */
async function load(
  tx: TenantTransaction,
  companyId: string,
  from: string,
  to: string,
  filter: { employeeId?: string; departmentId?: string | null },
): Promise<Loaded> {
  const company = await tx.company.findUniqueOrThrow({
    where: { id: companyId },
    select: { timeZone: true, kpiTarget: true },
  });
  const employees = await tx.employee.findMany({
    where: {
      employmentStatus: 'ACTIVE',
      ...(filter.employeeId ? { id: filter.employeeId } : {}),
      ...(filter.departmentId ? { departmentId: filter.departmentId } : {}),
    },
    select: {
      id: true,
      employeeNumber: true,
      givenNames: true,
      familyNames: true,
      hiredOn: true,
      department: {
        select: {
          id: true,
          name: true,
          entryMinutes: true,
          exitMinutes: true,
          toleranceMinutes: true,
          workDays: true,
        },
      },
    },
    orderBy: [{ familyNames: 'asc' }, { givenNames: 'asc' }],
  });
  // Un día de margen a cada lado por la zona horaria.
  const events = await tx.attendanceEvent.findMany({
    where: {
      employeeId: { in: employees.map((employee) => employee.id) },
      eventType: { in: ['ENTRY', 'EXIT'] },
      deviceOccurredAt: {
        gte: new Date(`${addDays(from, -1)}T00:00:00Z`),
        lt: new Date(`${addDays(to, 1)}T00:00:00Z`),
      },
    },
    select: {
      employeeId: true,
      eventType: true,
      captureMethod: true,
      deviceOccurredAt: true,
      requiresReview: true,
      review: { select: { decision: true } },
    },
  });
  const holidays = await tx.holiday.findMany({
    where: {
      day: {
        gte: new Date(`${from}T00:00:00Z`),
        lt: new Date(`${to}T00:00:00Z`),
      },
    },
    select: { day: true, departmentId: true },
  });
  const byEmployee = new Map<string, KpiEmployeeInput['events']>();
  for (const event of events) {
    if (!event.employeeId) continue;
    const list = byEmployee.get(event.employeeId) ?? [];
    list.push({
      type: event.eventType as 'ENTRY' | 'EXIT',
      at: event.deviceOccurredAt,
      captureMethod: event.captureMethod,
      status: reviewStatus(event.requiresReview, event.review?.decision),
    });
    byEmployee.set(event.employeeId, list);
  }
  return {
    targets: company.kpiTarget ?? DEFAULT_TARGETS,
    context: {
      timeZone: company.timeZone,
      now: new Date(),
      holidays: holidays.map((holiday) => ({
        day: holiday.day.toISOString().slice(0, 10),
        departmentId: holiday.departmentId,
      })),
    },
    employees: employees.map((employee) => ({
      id: employee.id,
      employeeNumber: employee.employeeNumber,
      name: `${employee.givenNames} ${employee.familyNames}`,
      department: employee.department && {
        id: employee.department.id,
        name: employee.department.name,
      },
      input: {
        departmentId: employee.department?.id ?? null,
        hiredOn: employee.hiredOn.toISOString().slice(0, 10),
        events: byEmployee.get(employee.id) ?? [],
        schedule: employee.department && {
          departmentName: employee.department.name,
          entryMinutes: employee.department.entryMinutes,
          exitMinutes: employee.department.exitMinutes,
          toleranceMinutes: employee.department.toleranceMinutes,
          workDays: employee.department.workDays,
        },
      },
    })),
  };
}

function row(
  employee: Loaded['employees'][number],
  period: Period,
  loaded: Loaded,
  today: string,
) {
  const current = computeKpis(employee.input, period, loaded.context);
  const previous = computeKpis(
    employee.input,
    previousPeriod(period),
    loaded.context,
  );
  // Bradford: 52 semanas que terminan al cerrar el periodo (o hoy, si aún corre).
  const end = period.end <= today ? period.end : addDays(today, 1);
  const score = bradford(employee.input, end, loaded.context);
  return {
    employee: {
      id: employee.id,
      employeeNumber: employee.employeeNumber,
      name: employee.name,
      department: employee.department,
    },
    period,
    values: current.values,
    previous: previous.values,
    bradford: score,
    lights: {
      attendance: rateLight(
        current.values.attendanceRate,
        loaded.targets.attendanceMin,
      ),
      punctuality: rateLight(
        current.values.punctualityRate,
        loaded.targets.punctualityMin,
      ),
      bradford: bradfordLight(score.score, loaded.targets),
    },
    days: current.days,
  };
}

@Controller('kpis')
export class KpisController {
  constructor(@Inject(TenantDatabase) private readonly db: TenantDatabase) {}

  private async today(
    tx: TenantTransaction,
    companyId: string,
  ): Promise<string> {
    const company = await tx.company.findUniqueOrThrow({
      where: { id: companyId },
      select: { timeZone: true },
    });
    return localTime(new Date(), company.timeZone).day;
  }

  /** Tablero: una fila por empleado activo, con semáforo y periodo anterior. */
  @RequirePermissions('kpis.read')
  @Get('employees')
  list(
    @CurrentAuth() auth: AuthContext,
    @Query('period') kind?: string,
    @Query('anchor') anchor?: string,
    @Query('departmentId') rawDepartment?: string,
  ) {
    const departmentId = optionalUuid(
      { departmentId: rawDepartment },
      'departmentId',
      'El departamento',
    );
    return this.db.run(auth.companyId, async (tx) => {
      const today = await this.today(tx, auth.companyId);
      const period = readPeriod(kind, anchor, today);
      const loaded = await load(
        tx,
        auth.companyId,
        addDays(period.end, -364 - 7),
        period.end,
        { departmentId },
      );
      return {
        period,
        targets: loaded.targets,
        rows: loaded.employees.map((employee) => {
          const { days: _days, ...rest } = row(employee, period, loaded, today);
          return rest;
        }),
      };
    });
  }

  /** Ficha: KPIs del periodo, detalle por día y serie de los últimos 6 periodos. */
  @RequirePermissions('kpis.read')
  @Get('employees/:id')
  detail(
    @CurrentAuth() auth: AuthContext,
    @Param('id') rawId: string,
    @Query('period') kind?: string,
    @Query('anchor') anchor?: string,
  ) {
    const id = uuid(rawId, 'El empleado');
    return this.db.run(auth.companyId, async (tx) => {
      const today = await this.today(tx, auth.companyId);
      const period = readPeriod(kind, anchor, today);
      const periods = [period];
      while (periods.length < SERIES_LENGTH)
        periods.unshift(previousPeriod(periods[0]));
      // Lo que empiece antes: la serie de 6 periodos o las 52 semanas de Bradford.
      const bradfordFrom = addDays(period.end, -364 - 7);
      const from =
        bradfordFrom < periods[0].start ? bradfordFrom : periods[0].start;
      const loaded = await load(tx, auth.companyId, from, period.end, {
        employeeId: id,
      });
      const employee = loaded.employees[0];
      if (!employee)
        throw new NotFoundException(
          'El empleado no existe o está dado de baja.',
        );
      return {
        targets: loaded.targets,
        ...row(employee, period, loaded, today),
        series: periods.map((each) => ({
          period: each,
          values: computeKpis(employee.input, each, loaded.context).values,
        })),
      };
    });
  }

  @RequirePermissions('kpis.read')
  @Get('targets')
  targets(@CurrentAuth() auth: AuthContext) {
    return this.db.run(auth.companyId, async (tx) => {
      const target = await tx.kpiTarget.findUnique({
        where: { companyId: auth.companyId },
      });
      return target
        ? {
            attendanceMin: target.attendanceMin,
            punctualityMin: target.punctualityMin,
            bradfordWarning: target.bradfordWarning,
            bradfordAlert: target.bradfordAlert,
          }
        : DEFAULT_TARGETS;
    });
  }

  @RequirePermissions('kpis.manage')
  @Put('targets')
  saveTargets(@CurrentAuth() auth: AuthContext, @Body() raw: unknown) {
    const body = readBody(raw);
    const data = {
      attendanceMin: integer(
        body,
        'attendanceMin',
        'La asistencia mínima',
        0,
        100,
      ),
      punctualityMin: integer(
        body,
        'punctualityMin',
        'La puntualidad mínima',
        0,
        100,
      ),
      bradfordWarning: integer(
        body,
        'bradfordWarning',
        'El aviso de Bradford',
        1,
        10000,
      ),
      bradfordAlert: integer(
        body,
        'bradfordAlert',
        'La alerta de Bradford',
        2,
        10000,
      ),
    };
    if (data.bradfordAlert <= data.bradfordWarning) {
      throw new BadRequestException(
        'La alerta de Bradford debe ser mayor que el aviso.',
      );
    }
    return this.db.run(auth.companyId, async (tx) => {
      await tx.kpiTarget.upsert({
        where: { companyId: auth.companyId },
        create: { companyId: auth.companyId, ...data },
        update: data,
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'kpi.targets_updated',
        entityType: 'company',
        entityId: auth.companyId,
        details: data,
      });
      return data;
    });
  }
}
