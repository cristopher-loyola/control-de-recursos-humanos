// Pre-nómina: funciones puras portadas de la tablet (lib/payroll/payroll.dart)
// con las mismas reglas. Montos en centavos; fechas como días AAAA-MM-DD.
import { addDays } from '../kpis/kpi-engine.js';

export type PayPeriod = 'weekly' | 'semimonthly' | 'monthly';

export interface PayrollPolicyRules {
  kind: PayPeriod;
  /** Día en que empieza la semana de pago: 1 = lunes … 7 = domingo. */
  weekStart: number;
  /** Días de salario que se pagan por periodo completo. */
  paidDays: number;
  /** Días de salario que descuenta cada falta. */
  absenceDays: number;
  /** Cuántos retardos equivalen a una falta; 0 = los retardos no descuentan. */
  latesPerAbsence: number;
}

export const DEFAULT_POLICY: PayrollPolicyRules = {
  kind: 'weekly',
  weekStart: 1,
  paidDays: 7,
  absenceDays: 1,
  latesPerAbsence: 0,
};

const DAY_MS = 86_400_000;

/** Días naturales entre dos fechas (to excluido). */
export function calendarDays(from: string, to: string): number {
  return Math.round(
    (Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / DAY_MS,
  );
}

function monthStart(year: number, month: number): string {
  const y = year + Math.floor((month - 1) / 12);
  const m = ((((month - 1) % 12) + 12) % 12) + 1;
  return `${y}-${String(m).padStart(2, '0')}-01`;
}

/** Rango [start, end) del periodo de pago que contiene `anchor`. */
export function payPeriodRange(
  policy: PayrollPolicyRules,
  anchor: string,
): { start: string; end: string } {
  const [year, month, day] = anchor.split('-').map(Number);
  switch (policy.kind) {
    case 'weekly': {
      // getUTCDay: 0 = domingo; se convierte a 1 = lunes … 7 = domingo.
      const weekday = new Date(`${anchor}T00:00:00Z`).getUTCDay() || 7;
      const back = (((weekday - policy.weekStart) % 7) + 7) % 7;
      const start = addDays(anchor, -back);
      return { start, end: addDays(start, 7) };
    }
    case 'semimonthly':
      return day <= 15
        ? {
            start: monthStart(year, month),
            end: `${monthStart(year, month).slice(0, 8)}16`,
          }
        : {
            start: `${monthStart(year, month).slice(0, 8)}16`,
            end: monthStart(year, month + 1),
          };
    case 'monthly':
      return {
        start: monthStart(year, month),
        end: monthStart(year, month + 1),
      };
  }
}

export interface PayrollLineInput {
  employeeNumber: string;
  name: string;
  departmentName: string | null;
  /** AAAA-MM-DD */
  hiredOn: string;
  hasSchedule: boolean;
  absences: number;
  lates: number;
  incomplete: number;
  employeeWage: number | null;
  departmentWage: number | null;
}

export interface PayrollLine {
  number: string;
  name: string;
  department: string | null;
  /** Salario diario aplicado; null si no hay salario capturado. */
  dailyWage: number | null;
  /** true si el salario es del empleado y no el de su departamento. */
  ownWage: boolean;
  paidDays: number;
  absences: number;
  lates: number;
  latesAsAbsences: number;
  /** Entradas sin salida en el periodo: se marcan, no se descuentan. */
  incomplete: number;
  gross: number | null;
  deduction: number | null;
  total: number | null;
}

/**
 * Lo que corresponde a cada empleado en el periodo, antes de impuestos.
 * - Base: salario diario × días pagados; si el alta fue dentro del periodo,
 *   la parte proporcional de los días que estuvo dado de alta.
 * - Descuento: (faltas + retardos ÷ N, sin decimales) × días por falta ×
 *   salario diario. Nunca supera la base.
 * - Sin departamento no hay horario contra qué medir: no se calcula monto.
 */
export function payrollLine(
  input: PayrollLineInput,
  policy: PayrollPolicyRules,
  period: { start: string; end: string },
): PayrollLine {
  const wage = input.employeeWage ?? input.departmentWage;
  const latesAsAbsences =
    policy.latesPerAbsence === 0
      ? 0
      : Math.floor(input.lates / policy.latesPerAbsence);
  const periodDays = calendarDays(period.start, period.end);
  const employedDays =
    input.hiredOn > period.start
      ? Math.min(
          Math.max(calendarDays(input.hiredOn, period.end), 0),
          periodDays,
        )
      : periodDays;
  const paidDays = (policy.paidDays * employedDays) / periodDays;
  let gross: number | null = null;
  let deduction: number | null = null;
  if (wage !== null && input.hasSchedule) {
    gross = Math.round(wage * paidDays);
    deduction = Math.min(
      gross,
      Math.round(
        wage * (input.absences + latesAsAbsences) * policy.absenceDays,
      ),
    );
  }
  return {
    number: input.employeeNumber,
    name: input.name,
    department: input.departmentName,
    dailyWage: wage,
    ownWage: input.employeeWage !== null,
    paidDays: Number(paidDays.toFixed(2)),
    absences: input.absences,
    lates: input.lates,
    latesAsAbsences,
    incomplete: input.incomplete,
    gross,
    deduction,
    total: gross === null || deduction === null ? null : gross - deduction,
  };
}
