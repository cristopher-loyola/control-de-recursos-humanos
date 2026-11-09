import {
  BadRequestException,
  Controller,
  Get,
  Inject,
  Query,
} from '@nestjs/common';
import { loadAttendance } from '../attendance/attendance-data.js';
import { localTime } from '../attendance/schedule.js';
import { CurrentAuth, RequirePermissions } from '../auth/access.js';
import type { AuthContext } from '../auth/access.js';
import { isoDate, optionalUuid } from '../common/input.js';
import { TenantDatabase } from '../database/tenant-database.js';
import { addDays, computeKpis } from '../kpis/kpi-engine.js';

/** Rango máximo del reporte, para que una consulta no recorra años. */
export const MAX_REPORT_DAYS = 93;

/**
 * Lee `from` y `to` (AAAA-MM-DD, `to` excluido). Sin fechas, el día de hoy en
 * la zona horaria de la empresa.
 */
export function readRange(
  from: string | undefined,
  to: string | undefined,
  today: string,
): { start: string; end: string } {
  const day = (value: string, key: string, label: string) =>
    isoDate({ [key]: value }, key, label)
      .toISOString()
      .slice(0, 10);
  const start = from ? day(from, 'from', 'La fecha inicial') : today;
  const end = to ? day(to, 'to', 'La fecha final') : addDays(start, 1);
  if (end <= start) {
    throw new BadRequestException(
      'La fecha final debe ser posterior a la inicial.',
    );
  }
  if (end > addDays(start, MAX_REPORT_DAYS)) {
    throw new BadRequestException(
      `El reporte abarca como máximo ${MAX_REPORT_DAYS} días.`,
    );
  }
  return { start, end };
}

@Controller('reports')
export class ReportsController {
  constructor(@Inject(TenantDatabase) private readonly db: TenantDatabase) {}

  /**
   * Asistencia de un rango: resumen y estado de cada día por empleado activo,
   * con las mismas reglas que los KPIs. Filtros: departamento (`none` = sin
   * departamento) y sucursal.
   */
  @RequirePermissions('reports.read')
  @Get('attendance')
  attendance(
    @CurrentAuth() auth: AuthContext,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('departmentId') rawDepartment?: string,
    @Query('branchId') rawBranch?: string,
  ) {
    const withoutDepartment = rawDepartment === 'none';
    const departmentId = withoutDepartment
      ? null
      : optionalUuid(
          { departmentId: rawDepartment },
          'departmentId',
          'El departamento',
        );
    const branchId = optionalUuid(
      { branchId: rawBranch },
      'branchId',
      'La sucursal',
    );
    return this.db.run(auth.companyId, async (tx) => {
      const company = await tx.company.findUniqueOrThrow({
        where: { id: auth.companyId },
        select: { timeZone: true },
      });
      const today = localTime(new Date(), company.timeZone).day;
      const period = readRange(from, to, today);
      const loaded = await loadAttendance(
        tx,
        auth.companyId,
        period.start,
        period.end,
        { departmentId, withoutDepartment, branchId },
      );
      const departments = await tx.department.findMany({
        where: { isActive: true },
        select: { id: true, name: true },
        orderBy: { name: 'asc' },
      });
      const summaries = loaded.employees.map((employee) => {
        const result = computeKpis(
          employee.input,
          { kind: 'range', ...period },
          loaded.context,
        );
        return {
          employee: {
            id: employee.id,
            employeeNumber: employee.employeeNumber,
            name: employee.name,
            hiredOn: employee.hiredOn,
            branch: employee.branch,
          },
          department: employee.department && {
            id: employee.department.id,
            name: employee.department.name,
          },
          hasSchedule: employee.input.schedule !== null,
          hasFace: employee.hasFace,
          values: result.values,
          days: result.days,
        };
      });
      // Festivos que aplican al filtro: los de toda la empresa y los del
      // departamento elegido.
      const holidays = loaded.holidays.filter(
        (holiday) =>
          holiday.departmentId === null ||
          (!withoutDepartment &&
            (departmentId === null || holiday.departmentId === departmentId)),
      );
      return {
        period,
        timeZone: company.timeZone,
        departments,
        holidays,
        pendingReviews: summaries.reduce(
          (total, row) => total + row.values.pendingReview,
          0,
        ),
        withoutFace: summaries.filter((row) => !row.hasFace).length,
        summaries,
      };
    });
  }
}
