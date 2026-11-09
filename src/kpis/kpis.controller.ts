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
import { loadAttendance } from '../attendance/attendance-data.js';
import type {
  LoadedAttendance,
  LoadedEmployee,
} from '../attendance/attendance-data.js';
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
import type { Period, PeriodKind } from './kpi-engine.js';
import { DEFAULT_TARGETS } from './kpi-targets.js';

export { DEFAULT_TARGETS };

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

function row(
  employee: LoadedEmployee,
  period: Period,
  loaded: LoadedAttendance,
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
      department: employee.department && {
        id: employee.department.id,
        name: employee.department.name,
      },
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
      const loaded = await loadAttendance(
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
      const loaded = await loadAttendance(
        tx,
        auth.companyId,
        from,
        period.end,
        {
          employeeId: id,
        },
      );
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
