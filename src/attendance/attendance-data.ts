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
      now: new Date(),
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
