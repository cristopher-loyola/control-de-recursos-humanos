// Lectura común de asistencia para KPIs, reporte y pre-nómina: empleados con
// su horario, checadas de las tablets (con su revisión), checadas manuales de
// RH y festivos. Pocas consultas; el cálculo se hace en memoria con
// computeKpis.
import { DEFAULT_TARGETS } from '../kpis/kpi-targets.js';
import { addDays } from '../kpis/kpi-engine.js';
import type {
  KpiContext,
  KpiEmployeeInput,
  KpiTargets,
} from '../kpis/kpi-engine.js';
import type { TenantTransaction } from '../database/tenant-database.js';
import { reviewStatus } from './review-status.js';
import { localTime } from './schedule.js';

export interface AttendanceFilter {
  employeeId?: string;
  departmentId?: string | null;
  /** Solo empleados sin departamento. */
  withoutDepartment?: boolean;
  branchId?: string | null;
}

export interface LoadedEmployee {
  id: string;
  employeeNumber: string;
  name: string;
  hiredOn: string;
  /** Desde cuándo se mide su asistencia (ver `countsFrom`). */
  countsFrom: string;
  branch: { id: string; name: string };
  department: {
    id: string;
    name: string;
    dailyWageCents: number | null;
  } | null;
  dailyWageCents: number | null;
  hasFace: boolean;
  input: KpiEmployeeInput;
}

export interface LoadedAttendance {
  context: KpiContext;
  targets: KpiTargets;
  holidays: {
    id: string;
    day: string;
    name: string;
    departmentId: string | null;
  }[];
  employees: LoadedEmployee[];
}

/**
 * Primer día en que se mide la asistencia de un empleado: el más tardío
 * entre su fecha de ingreso, el día en que se registró en el sistema y el
 * día de la primera checada de su sucursal. Antes de eso la persona no podía
 * checar, así que esos días no cuentan como asistencia ni como falta. Si la
 * sucursal todavía no tiene checadas, se mide a partir de mañana (nada).
 * La pre-nómina sigue pagando desde la fecha de ingreso.
 */
export function countsFrom(dates: {
  hiredOn: string;
  registeredOn: string;
  branchStart: string | null;
  today: string;
}): string {
  const branchStart = dates.branchStart ?? addDays(dates.today, 1);
  return [dates.hiredOn, dates.registeredOn, branchStart].reduce((a, b) =>
    b > a ? b : a,
  );
}

/**
 * Día local de la primera checada de cada sucursal (de tablet o capturada
 * por RH), contando a todos sus empleados, también los dados de baja.
 * Una consulta por sucursal; las interactivas no admiten consultas en
 * paralelo.
 */
async function branchStarts(
  tx: TenantTransaction,
  branchIds: string[],
  timeZone: string,
): Promise<Map<string, string>> {
  const starts = new Map<string, string>();
  for (const branchId of branchIds) {
    const event = await tx.attendanceEvent.findFirst({
      where: { employee: { is: { branchId } } },
      orderBy: { deviceOccurredAt: 'asc' },
      select: { deviceOccurredAt: true },
    });
    const manual = await tx.manualAttendanceEntry.findFirst({
      where: { employee: { branchId } },
      orderBy: { occurredAt: 'asc' },
      select: { occurredAt: true },
    });
    const first = [event?.deviceOccurredAt, manual?.occurredAt]
      .filter((at): at is Date => at !== undefined)
      .sort((a, b) => a.getTime() - b.getTime())[0];
    if (first) starts.set(branchId, localTime(first, timeZone).day);
  }
  return starts;
}

/**
 * Empleados activos que cumplen el filtro y su asistencia en [from, to)
 * (días locales AAAA-MM-DD), con un día de margen por la zona horaria.
 */
export async function loadAttendance(
  tx: TenantTransaction,
  companyId: string,
  from: string,
  to: string,
  filter: AttendanceFilter = {},
): Promise<LoadedAttendance> {
  const company = await tx.company.findUniqueOrThrow({
    where: { id: companyId },
    select: { timeZone: true, kpiTarget: true },
  });
  const employees = await tx.employee.findMany({
    where: {
      employmentStatus: 'ACTIVE',
      ...(filter.employeeId ? { id: filter.employeeId } : {}),
      ...(filter.withoutDepartment
        ? { departmentId: null }
        : filter.departmentId
          ? { departmentId: filter.departmentId }
          : {}),
      ...(filter.branchId ? { branchId: filter.branchId } : {}),
    },
    select: {
      id: true,
      employeeNumber: true,
      givenNames: true,
      familyNames: true,
      hiredOn: true,
      createdAt: true,
      dailyWageCents: true,
      branch: { select: { id: true, name: true } },
      faceTemplates: {
        where: { revokedAt: null },
        take: 1,
        select: { id: true },
      },
      department: {
        select: {
          id: true,
          name: true,
          entryMinutes: true,
          exitMinutes: true,
          toleranceMinutes: true,
          workDays: true,
          dailyWageCents: true,
        },
      },
    },
    orderBy: [{ familyNames: 'asc' }, { givenNames: 'asc' }],
  });
  const ids = employees.map((employee) => employee.id);
  const window = {
    gte: new Date(`${addDays(from, -1)}T00:00:00Z`),
    lt: new Date(`${addDays(to, 1)}T00:00:00Z`),
  };
  const events = await tx.attendanceEvent.findMany({
    where: {
      employeeId: { in: ids },
      eventType: { in: ['ENTRY', 'EXIT'] },
      deviceOccurredAt: window,
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
  const manual = await tx.manualAttendanceEntry.findMany({
    where: {
      employeeId: { in: ids },
      eventType: { in: ['ENTRY', 'EXIT'] },
      occurredAt: window,
    },
    select: { employeeId: true, eventType: true, occurredAt: true },
  });
  const holidays = await tx.holiday.findMany({
    where: {
      day: {
        gte: new Date(`${from}T00:00:00Z`),
        lt: new Date(`${to}T00:00:00Z`),
      },
    },
    select: { id: true, day: true, name: true, departmentId: true },
    orderBy: { day: 'asc' },
  });
  const byEmployee = new Map<string, KpiEmployeeInput['events']>();
  const push = (employeeId: string, event: KpiEmployeeInput['events'][0]) => {
    const list = byEmployee.get(employeeId) ?? [];
    list.push(event);
    byEmployee.set(employeeId, list);
  };
  for (const event of events) {
    if (!event.employeeId) continue;
    push(event.employeeId, {
      type: event.eventType as 'ENTRY' | 'EXIT',
      at: event.deviceOccurredAt,
      captureMethod: event.captureMethod,
      status: reviewStatus(event.requiresReview, event.review?.decision),
    });
  }
  // Las capturó RH con motivo: cuentan como aprobadas.
  for (const entry of manual) {
    push(entry.employeeId, {
      type: entry.eventType as 'ENTRY' | 'EXIT',
      at: entry.occurredAt,
      captureMethod: 'MANUAL',
      status: 'approved',
    });
  }
  const now = new Date();
  const today = localTime(now, company.timeZone).day;
  const starts = await branchStarts(
    tx,
    [...new Set(employees.map((employee) => employee.branch.id))],
    company.timeZone,
  );
  const measuredFrom = (employee: (typeof employees)[number]) =>
    countsFrom({
      hiredOn: employee.hiredOn.toISOString().slice(0, 10),
      registeredOn: localTime(employee.createdAt, company.timeZone).day,
      branchStart: starts.get(employee.branch.id) ?? null,
      today,
    });
  const holidayRows = holidays.map((holiday) => ({
    id: holiday.id,
    day: holiday.day.toISOString().slice(0, 10),
    name: holiday.name,
    departmentId: holiday.departmentId,
  }));
  return {
    targets: company.kpiTarget ?? DEFAULT_TARGETS,
    holidays: holidayRows,
    context: {
      timeZone: company.timeZone,
      now,
      holidays: holidayRows.map(({ day, departmentId }) => ({
        day,
        departmentId,
      })),
    },
    employees: employees.map((employee) => ({
      id: employee.id,
      employeeNumber: employee.employeeNumber,
      name: `${employee.givenNames} ${employee.familyNames}`,
      hiredOn: employee.hiredOn.toISOString().slice(0, 10),
      countsFrom: measuredFrom(employee),
      branch: employee.branch,
      dailyWageCents: employee.dailyWageCents,
      hasFace: employee.faceTemplates.length > 0,
      department: employee.department && {
        id: employee.department.id,
        name: employee.department.name,
        dailyWageCents: employee.department.dailyWageCents,
      },
      input: {
        departmentId: employee.department?.id ?? null,
        countsFrom: measuredFrom(employee),
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
