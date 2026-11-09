// Motor de KPIs de empleado. Funciones puras: reciben checadas, horario y
// festivos y devuelven los indicadores. Las reglas de día son las mismas que el
// tablero de la tablet (buildReport): solo días laborables del departamento,
// desde la fecha de ingreso, sin festivos; hoy queda pendiente hasta la hora de
// entrada más la tolerancia.
import type { ReviewStatus } from '../attendance/review-status.js';
import { lateMinutes, localTime } from '../attendance/schedule.js';

/** range: rango libre del reporte de asistencia (no tiene periodo anterior). */
export type PeriodKind = 'week' | 'month' | 'quarter' | 'range';
export type Light = 'ok' | 'warning' | 'alert';

export interface Period {
  kind: PeriodKind;
  /** AAAA-MM-DD, incluido. */
  start: string;
  /** AAAA-MM-DD, excluido. */
  end: string;
}

export interface KpiSchedule {
  departmentName: string;
  entryMinutes: number;
  exitMinutes: number;
  toleranceMinutes: number;
  /** Máscara: bit 0 = lunes … bit 6 = domingo. */
  workDays: number;
}

export interface KpiEvent {
  type: 'ENTRY' | 'EXIT';
  at: Date;
  /** MANUAL: capturada por RH en el panel. */
  captureMethod: 'FACIAL' | 'PIN' | 'MANUAL_BACKUP' | 'MANUAL';
  status: ReviewStatus;
}

export interface KpiEmployeeInput {
  departmentId: string | null;
  schedule: KpiSchedule | null;
  /** AAAA-MM-DD */
  hiredOn: string;
  events: KpiEvent[];
}

export interface KpiContext {
  timeZone: string;
  holidays: { day: string; departmentId: string | null }[];
  now: Date;
}

export interface KpiTargets {
  attendanceMin: number;
  punctualityMin: number;
  bradfordWarning: number;
  bradfordAlert: number;
}

export type DayStatus = 'onTime' | 'late' | 'absent' | 'pending';

export interface KpiDay {
  day: string;
  status: DayStatus;
  holiday: boolean;
  entryAt: Date | null;
  lateBy: number | null;
}

export interface KpiValues {
  scheduledDays: number;
  attendedDays: number;
  absences: number;
  onTime: number;
  lates: number;
  lateMinutes: number;
  earlyExits: number;
  earlyMinutes: number;
  workedMinutes: number;
  scheduledMinutes: number;
  overtimeMinutes: number;
  incompleteShifts: number;
  pinChecks: number;
  pendingReview: number;
  attendanceRate: number | null;
  absenteeismRate: number | null;
  punctualityRate: number | null;
  hoursRate: number | null;
}

/** Turno con más de 18 h sin salida queda incompleto (igual que la tablet). */
const OPEN_SHIFT_MS = 18 * 60 * 60_000;
const DAY_MS = 86_400_000;

function mod(value: number, divisor: number): number {
  return ((value % divisor) + divisor) % divisor;
}

export function addDays(day: string, days: number): string {
  return new Date(Date.parse(`${day}T00:00:00Z`) + days * DAY_MS)
    .toISOString()
    .slice(0, 10);
}

/** 0 = lunes … 6 = domingo. */
function weekdayIndex(day: string): number {
  return mod(new Date(`${day}T00:00:00Z`).getUTCDay() - 1, 7);
}

export function periodFor(kind: PeriodKind, anchor: string): Period {
  const [year, month] = anchor.split('-').map(Number);
  if (kind === 'week') {
    const start = addDays(anchor, -weekdayIndex(anchor));
    return { kind, start, end: addDays(start, 7) };
  }
  const first = kind === 'month' ? month : month - mod(month - 1, 3);
  const span = kind === 'month' ? 1 : 3;
  const iso = (y: number, m: number) =>
    `${y + Math.floor((m - 1) / 12)}-${String(mod(m - 1, 12) + 1).padStart(2, '0')}-01`;
  return { kind, start: iso(year, first), end: iso(year, first + span) };
}

export function previousPeriod(period: Period): Period {
  return periodFor(period.kind, addDays(period.start, -1));
}

function scheduledLength(schedule: KpiSchedule): number {
  return mod(schedule.exitMinutes - schedule.entryMinutes, 1440) || 1440;
}

interface Shift {
  entry: Date;
  exit: Date | null;
  /** Entrada sin salida y ya pasaron 18 h: jornada incompleta. */
  incomplete: boolean;
}

/** Empareja entrada → salida en orden; una salida suelta no forma turno. */
function shifts(events: KpiEvent[], now: Date): Shift[] {
  const ordered = [...events].sort((a, b) => a.at.getTime() - b.at.getTime());
  const result: Shift[] = [];
  let open: Date | null = null;
  const close = (exit: Date | null) => {
    if (!open) return;
    result.push({
      entry: open,
      exit,
      incomplete:
        exit === null && now.getTime() - open.getTime() >= OPEN_SHIFT_MS,
    });
    open = null;
  };
  for (const event of ordered) {
    if (event.type === 'ENTRY') {
      close(null);
      open = event.at;
    } else if (open && event.at.getTime() - open.getTime() < OPEN_SHIFT_MS) {
      close(event.at);
    } else {
      close(null);
    }
  }
  close(null);
  return result;
}

export interface EmployeeKpis {
  values: KpiValues;
  days: KpiDay[];
}

export function computeKpis(
  input: KpiEmployeeInput,
  period: Period,
  context: KpiContext,
): EmployeeKpis {
  const { timeZone, now } = context;
  const counted = input.events.filter((event) => event.status !== 'rejected');
  const local = (at: Date) => localTime(at, timeZone);
  const inPeriod = (day: string) => day >= period.start && day < period.end;
  const today = local(now);
  const schedule = input.schedule;

  const firstEntry = new Map<string, Date>();
  for (const event of [...counted].sort(
    (a, b) => a.at.getTime() - b.at.getTime(),
  )) {
    if (event.type !== 'ENTRY') continue;
    const day = local(event.at).day;
    if (!firstEntry.has(day)) firstEntry.set(day, event.at);
  }
  const isHoliday = (day: string) =>
    context.holidays.some(
      (holiday) =>
        holiday.day === day &&
        (holiday.departmentId === null ||
          holiday.departmentId === input.departmentId),
    );

  const days: KpiDay[] = [];
  const scheduledDays = new Set<string>();
  if (schedule) {
    const from = input.hiredOn > period.start ? input.hiredOn : period.start;
    for (
      let day = from;
      day < period.end && day <= today.day;
      day = addDays(day, 1)
    ) {
      if ((schedule.workDays & (1 << weekdayIndex(day))) === 0) continue;
      const entry = firstEntry.get(day) ?? null;
      const holiday = isHoliday(day);
      if (holiday && !entry) continue;
      if (entry) {
        const late = lateMinutes(schedule, local(entry).minuteOfDay);
        days.push({
          day,
          status: late === null ? 'onTime' : 'late',
          holiday,
          entryAt: entry,
          lateBy: late,
        });
        scheduledDays.add(day);
        continue;
      }
      const waiting =
        day === today.day &&
        today.minuteOfDay <= schedule.entryMinutes + schedule.toleranceMinutes;
      days.push({
        day,
        status: waiting ? 'pending' : 'absent',
        holiday,
        entryAt: null,
        lateBy: null,
      });
      if (!waiting) scheduledDays.add(day);
    }
  }

  const count = (status: DayStatus) =>
    days.filter((day) => day.status === status).length;
  const onTime = count('onTime');
  const lates = count('late');
  const absences = count('absent');
  const attendedDays = onTime + lates;
  const scheduled = attendedDays + absences;

  let workedMinutes = 0;
  let overtimeMinutes = 0;
  let incompleteShifts = 0;
  let earlyExits = 0;
  let earlyMinutes = 0;
  for (const shift of shifts(counted, now)) {
    const day = local(shift.entry).day;
    if (!inPeriod(day)) continue;
    if (shift.incomplete) incompleteShifts += 1;
    if (!shift.exit) continue;
    const minutes = Math.round(
      (shift.exit.getTime() - shift.entry.getTime()) / 60_000,
    );
    workedMinutes += minutes;
    // Horas extra informativas: lo trabajado por encima del turno programado,
    // o todo el turno en un día de descanso o festivo (LFT art. 75).
    overtimeMinutes +=
      schedule && scheduledDays.has(day) && !isHoliday(day)
        ? Math.max(0, minutes - scheduledLength(schedule))
        : minutes;
    if (schedule && scheduledDays.has(day)) {
      const early = mod(
        schedule.exitMinutes - local(shift.exit).minuteOfDay,
        1440,
      );
      if (early > 0 && early < 720) {
        earlyExits += 1;
        earlyMinutes += early;
      }
    }
  }
  const scheduledMinutes = schedule ? scheduled * scheduledLength(schedule) : 0;
  // Incluye las rechazadas: una checada con PIN mide que el rostro no se
  // reconoció, aunque RH la haya rechazado después.
  const periodEvents = input.events.filter((event) =>
    inPeriod(local(event.at).day),
  );
  const ratio = (a: number, b: number) => (b === 0 ? null : a / b);

  return {
    days,
    values: {
      scheduledDays: scheduled,
      attendedDays,
      absences,
      onTime,
      lates,
      lateMinutes: days.reduce((total, day) => total + (day.lateBy ?? 0), 0),
      earlyExits,
      earlyMinutes,
      workedMinutes,
      scheduledMinutes,
      overtimeMinutes,
      incompleteShifts,
      pinChecks: periodEvents.filter((event) => event.captureMethod === 'PIN')
        .length,
      pendingReview: input.events.filter(
        (event) => event.status === 'pending' && inPeriod(local(event.at).day),
      ).length,
      attendanceRate: ratio(attendedDays, scheduled),
      absenteeismRate: ratio(absences, scheduled),
      punctualityRate: ratio(onTime, attendedDays),
      hoursRate: ratio(workedMinutes, scheduledMinutes),
    },
  };
}

/**
 * Factor Bradford = S² × D sobre las 52 semanas que terminan en `end`:
 * S = episodios de ausencia (faltas en días laborables seguidos cuentan como
 * uno), D = días de falta.
 */
export function bradford(
  input: KpiEmployeeInput,
  end: string,
  context: KpiContext,
): { spells: number; days: number; score: number } {
  const window: Period = { kind: 'week', start: addDays(end, -364), end };
  const { days } = computeKpis(input, window, context);
  let spells = 0;
  let previousAbsent = false;
  for (const day of days) {
    const absent = day.status === 'absent';
    if (absent && !previousAbsent) spells += 1;
    previousAbsent = absent;
  }
  const absences = days.filter((day) => day.status === 'absent').length;
  return { spells, days: absences, score: spells * spells * absences };
}

/** Semáforo de un porcentaje contra su meta mínima: aviso hasta 5 puntos abajo. */
export function rateLight(rate: number | null, min: number): Light | null {
  if (rate === null) return null;
  const percent = rate * 100;
  if (percent >= min) return 'ok';
  return percent >= min - 5 ? 'warning' : 'alert';
}

export function bradfordLight(score: number, targets: KpiTargets): Light {
  if (score >= targets.bradfordAlert) return 'alert';
  return score >= targets.bradfordWarning ? 'warning' : 'ok';
}
