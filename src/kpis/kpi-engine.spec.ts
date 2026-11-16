import { describe, expect, it } from 'vitest';
import {
  addDays,
  bradford,
  bradfordLight,
  computeKpis,
  periodFor,
  previousPeriod,
  rateLight,
} from './kpi-engine.js';
import type { KpiContext, KpiEmployeeInput, KpiEvent } from './kpi-engine.js';

// Ciudad de México es UTC-6 todo el año: 09:00 local = 15:00 UTC.
const TZ = 'America/Mexico_City';
const at = (day: string, hhmm: string) => {
  const [h, m] = hhmm.split(':').map(Number);
  return new Date(Date.parse(`${day}T00:00:00Z`) + ((h + 6) * 60 + m) * 60_000);
};
const ev = (
  type: 'ENTRY' | 'EXIT',
  day: string,
  hhmm: string,
  extra: Partial<KpiEvent> = {},
): KpiEvent => ({
  type,
  at: at(day, hhmm),
  captureMethod: 'FACIAL',
  status: 'approved',
  ...extra,
});

const office = {
  departmentName: 'Oficina',
  entryMinutes: 9 * 60,
  exitMinutes: 18 * 60,
  toleranceMinutes: 10,
  workDays: 31, // lunes a viernes
};

// Semana del lunes 2 al domingo 8 de noviembre de 2026.
const week = periodFor('week', '2026-11-04');
const context = (overrides: Partial<KpiContext> = {}): KpiContext => ({
  timeZone: TZ,
  holidays: [],
  now: at('2026-11-20', '12:00'),
  ...overrides,
});
const employee = (
  events: KpiEvent[],
  overrides: Partial<KpiEmployeeInput> = {},
): KpiEmployeeInput => ({
  departmentId: 'd1',
  schedule: office,
  countsFrom: '2026-01-01',
  events,
  ...overrides,
});

describe('Periodos', () => {
  it('semana de lunes a domingo, mes y trimestre', () => {
    expect(week).toEqual({
      kind: 'week',
      start: '2026-11-02',
      end: '2026-11-09',
    });
    expect(periodFor('month', '2026-11-20')).toMatchObject({
      start: '2026-11-01',
      end: '2026-12-01',
    });
    expect(periodFor('month', '2026-12-05')).toMatchObject({
      start: '2026-12-01',
      end: '2027-01-01',
    });
    expect(periodFor('quarter', '2026-11-20')).toMatchObject({
      start: '2026-10-01',
      end: '2027-01-01',
    });
    expect(previousPeriod(week)).toMatchObject({
      start: '2026-10-26',
      end: '2026-11-02',
    });
    expect(addDays('2026-12-31', 1)).toBe('2027-01-01');
  });
});

describe('Asistencia, puntualidad y faltas', () => {
  it('cuenta a tiempo, retardo en el límite de tolerancia y faltas solo en días laborables', () => {
    const { values } = computeKpis(
      employee([
        ev('ENTRY', '2026-11-02', '09:10'), // dentro de tolerancia
        ev('EXIT', '2026-11-02', '18:00'),
        ev('ENTRY', '2026-11-03', '09:11'), // retardo de 11 min
        ev('EXIT', '2026-11-03', '18:05'),
        ev('ENTRY', '2026-11-04', '08:50'),
        ev('EXIT', '2026-11-04', '17:30'), // salida anticipada 30 min
        // jueves 5: falta · viernes 6: falta · sábado y domingo no cuentan
      ]),
      week,
      context(),
    );
    expect(values).toMatchObject({
      scheduledDays: 5,
      attendedDays: 3,
      absences: 2,
      onTime: 2,
      lates: 1,
      lateMinutes: 11,
      earlyExits: 1,
      earlyMinutes: 30,
      attendanceRate: 3 / 5,
      absenteeismRate: 2 / 5,
      punctualityRate: 2 / 3,
    });
  });

  it('un festivo no es falta, pero si se trabajó cuenta como asistencia', () => {
    const holidays = [
      { day: '2026-11-05', departmentId: null },
      { day: '2026-11-06', departmentId: 'd1' },
    ];
    const { values } = computeKpis(
      employee([
        ev('ENTRY', '2026-11-06', '09:00'),
        ev('EXIT', '2026-11-06', '13:00'),
      ]),
      week,
      context({ holidays }),
    );
    // lun a mié: faltas (3) · jue festivo sin entrada: no cuenta · vie festivo trabajado: asistencia
    expect(values).toMatchObject({
      scheduledDays: 4,
      absences: 3,
      attendedDays: 1,
    });
    // Todo lo trabajado en festivo es tiempo extra informativo.
    expect(values.overtimeMinutes).toBe(240);
  });

  it('hoy queda pendiente hasta la hora de entrada más la tolerancia', () => {
    const before = computeKpis(
      employee([]),
      week,
      context({ now: at('2026-11-02', '09:05') }),
    );
    expect(before.values.scheduledDays).toBe(0);
    expect(before.days[0].status).toBe('pending');
    const after = computeKpis(
      employee([]),
      week,
      context({ now: at('2026-11-02', '09:30') }),
    );
    expect(after.values.absences).toBe(1);
  });

  it('no cuenta días antes del ingreso', () => {
    const { values } = computeKpis(
      employee([], { countsFrom: '2026-11-05' }),
      week,
      context(),
    );
    expect(values.scheduledDays).toBe(2);
  });

  it('una checada rechazada por RH no cuenta; una pendiente sí, y se reporta', () => {
    const { values } = computeKpis(
      employee([
        ev('ENTRY', '2026-11-02', '09:00', {
          status: 'rejected',
          captureMethod: 'PIN',
        }),
        ev('ENTRY', '2026-11-03', '09:00', {
          status: 'pending',
          captureMethod: 'PIN',
        }),
      ]),
      week,
      context(),
    );
    expect(values).toMatchObject({
      attendedDays: 1,
      absences: 4,
      pendingReview: 1,
      pinChecks: 2,
    });
  });

  it('sin departamento no hay horario: los KPIs de horario quedan vacíos', () => {
    const { values } = computeKpis(
      employee(
        [ev('ENTRY', '2026-11-02', '09:00'), ev('EXIT', '2026-11-02', '17:00')],
        {
          schedule: null,
          departmentId: null,
        },
      ),
      week,
      context(),
    );
    expect(values).toMatchObject({
      scheduledDays: 0,
      attendanceRate: null,
      punctualityRate: null,
      workedMinutes: 480,
    });
  });
});

describe('Horas trabajadas', () => {
  it('suma turnos, marca horas extra e incompletas', () => {
    const { values } = computeKpis(
      employee([
        ev('ENTRY', '2026-11-02', '09:00'),
        ev('EXIT', '2026-11-02', '20:00'), // 11 h: 2 h extra sobre 9 programadas
        ev('ENTRY', '2026-11-03', '09:00'), // sin salida: incompleta
        ev('ENTRY', '2026-11-04', '09:00'),
        ev('EXIT', '2026-11-04', '18:00'),
        ev('ENTRY', '2026-11-07', '10:00'), // sábado: todo es extra
        ev('EXIT', '2026-11-07', '12:00'),
      ]),
      week,
      context(),
    );
    expect(values).toMatchObject({
      workedMinutes: 660 + 540 + 120,
      overtimeMinutes: 120 + 120,
      incompleteShifts: 1,
      scheduledMinutes: 5 * 540,
    });
  });

  it('turno nocturno que cruza la medianoche', () => {
    const night = {
      ...office,
      entryMinutes: 22 * 60,
      exitMinutes: 6 * 60,
      workDays: 127,
    };
    const { values } = computeKpis(
      employee(
        [ev('ENTRY', '2026-11-02', '22:05'), ev('EXIT', '2026-11-03', '06:00')],
        {
          schedule: night,
        },
      ),
      { kind: 'week', start: '2026-11-02', end: '2026-11-03' },
      context(),
    );
    expect(values).toMatchObject({
      onTime: 1,
      workedMinutes: 475,
      overtimeMinutes: 0,
      earlyExits: 0,
    });
  });
});

describe('Factor Bradford y semáforos', () => {
  it('S² × D: tres faltas seguidas pesan menos que tres sueltas', () => {
    const present = (days: string[]) =>
      days.flatMap((day) => [
        ev('ENTRY', day, '09:00'),
        ev('EXIT', day, '18:00'),
      ]);
    const ctx = context({ now: at('2026-11-14', '12:00') });
    const lastYear = { countsFrom: '2026-11-02' };
    // Semanas del 2 y del 9 de noviembre: 10 días laborables.
    const allDays = Array.from({ length: 12 }, (_, i) =>
      addDays('2026-11-02', i),
    );
    const together = present(
      allDays.filter(
        (d) => !['2026-11-04', '2026-11-05', '2026-11-06'].includes(d),
      ),
    );
    const apart = present(
      allDays.filter(
        (d) => !['2026-11-02', '2026-11-05', '2026-11-11'].includes(d),
      ),
    );
    expect(bradford(employee(together, lastYear), '2026-11-14', ctx)).toEqual({
      spells: 1,
      days: 3,
      score: 3,
    });
    expect(bradford(employee(apart, lastYear), '2026-11-14', ctx)).toEqual({
      spells: 3,
      days: 3,
      score: 27,
    });
  });

  it('faltas de viernes y lunes seguidos son un solo episodio', () => {
    const ctx = context({ now: at('2026-11-10', '12:00') });
    const events = [
      ev('ENTRY', '2026-11-05', '09:00'),
      ev('ENTRY', '2026-11-10', '09:00'),
    ];
    expect(
      bradford(
        employee(events, { countsFrom: '2026-11-05' }),
        '2026-11-11',
        ctx,
      ),
    ).toEqual({
      spells: 1,
      days: 2,
      score: 2,
    });
  });

  it('semáforo contra la meta: aviso hasta 5 puntos abajo', () => {
    expect(rateLight(0.96, 95)).toBe('ok');
    expect(rateLight(0.91, 95)).toBe('warning');
    expect(rateLight(0.8, 95)).toBe('alert');
    expect(rateLight(null, 95)).toBeNull();
    const targets = {
      attendanceMin: 95,
      punctualityMin: 90,
      bradfordWarning: 51,
      bradfordAlert: 201,
    };
    expect(bradfordLight(27, targets)).toBe('ok');
    expect(bradfordLight(64, targets)).toBe('warning');
    expect(bradfordLight(250, targets)).toBe('alert');
  });
});
