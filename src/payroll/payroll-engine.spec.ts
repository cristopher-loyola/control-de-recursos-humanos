import { describe, expect, it } from 'vitest';
import {
  DEFAULT_POLICY,
  payPeriodRange,
  payrollLine,
} from './payroll-engine.js';
import type { PayrollLineInput } from './payroll-engine.js';

// Mismos casos que test/payroll_test.dart de la tablet.
describe('Periodos de pago', () => {
  it('calcula semanas que empiezan en jueves', () => {
    expect(
      payPeriodRange({ ...DEFAULT_POLICY, weekStart: 4 }, '2026-11-02'),
    ).toEqual({ start: '2026-10-29', end: '2026-11-05' });
  });

  it('calcula quincenas', () => {
    const policy = { ...DEFAULT_POLICY, kind: 'semimonthly' as const };
    expect(payPeriodRange(policy, '2026-11-20')).toEqual({
      start: '2026-11-16',
      end: '2026-12-01',
    });
    expect(payPeriodRange(policy, '2026-10-31')).toEqual({
      start: '2026-10-16',
      end: '2026-11-01',
    });
    expect(payPeriodRange(policy, '2026-11-15')).toEqual({
      start: '2026-11-01',
      end: '2026-11-16',
    });
  });

  it('calcula meses, también al cruzar el año', () => {
    const policy = { ...DEFAULT_POLICY, kind: 'monthly' as const };
    expect(payPeriodRange(policy, '2026-12-31')).toEqual({
      start: '2026-12-01',
      end: '2027-01-01',
    });
  });
});

describe('Renglón de pre-nómina', () => {
  const week = { start: '2026-10-26', end: '2026-11-02' };
  const ana: PayrollLineInput = {
    employeeNumber: '1',
    name: 'Ana',
    departmentName: 'Producción',
    hiredOn: '2026-01-01',
    hasSchedule: true,
    absences: 1,
    lates: 3,
    incomplete: 0,
    employeeWage: null,
    departmentWage: 30000,
  };

  it('descuenta faltas y convierte retardos en faltas', () => {
    const line = payrollLine(
      ana,
      { ...DEFAULT_POLICY, latesPerAbsence: 2, absenceDays: 1.5 },
      week,
    );
    expect(line.gross).toBe(7 * 30000);
    expect(line.latesAsAbsences).toBe(1);
    // (1 falta + 1 por retardos) × 1.5 días × $300.
    expect(line.deduction).toBe(90000);
    expect(line.total).toBe(120000);
    expect(line.ownWage).toBe(false);
  });

  it('usa el salario propio antes que el del departamento', () => {
    const line = payrollLine(
      { ...ana, employeeWage: 40000 },
      DEFAULT_POLICY,
      week,
    );
    expect(line.dailyWage).toBe(40000);
    expect(line.ownWage).toBe(true);
    expect(line.latesAsAbsences).toBe(0);
    expect(line.deduction).toBe(40000);
  });

  it('paga proporcional si el alta fue dentro del periodo', () => {
    const line = payrollLine(
      {
        ...ana,
        hiredOn: '2026-10-30',
        absences: 0,
        lates: 0,
        departmentWage: 35000,
      },
      DEFAULT_POLICY,
      week,
    );
    expect(line.paidDays).toBe(3);
    expect(line.gross).toBe(105000);
  });

  it('el descuento nunca supera la base', () => {
    const line = payrollLine(
      { ...ana, absences: 9 },
      { ...DEFAULT_POLICY, absenceDays: 2 },
      week,
    );
    expect(line.deduction).toBe(line.gross);
    expect(line.total).toBe(0);
  });

  it('sin departamento no calcula montos', () => {
    const line = payrollLine(
      { ...ana, departmentName: null, hasSchedule: false },
      DEFAULT_POLICY,
      week,
    );
    expect(line.gross).toBeNull();
    expect(line.deduction).toBeNull();
    expect(line.total).toBeNull();
  });
});
