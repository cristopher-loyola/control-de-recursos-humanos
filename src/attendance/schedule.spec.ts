import { describe, expect, it } from 'vitest';
import { lateMinutes, localTime, scheduleIssue } from './schedule.js';

const day = {
  departmentName: 'Almacén',
  entryMinutes: 9 * 60,
  exitMinutes: 18 * 60,
  toleranceMinutes: 10,
};
const night = { ...day, entryMinutes: 22 * 60, exitMinutes: 6 * 60 };

// La app de la tablet aplica las mismas reglas sin red.
describe('Horario (igual que el kiosco)', () => {
  it('entrada dentro de la tolerancia no tiene retardo', () => {
    expect(lateMinutes(day, 9 * 60 + 10)).toBeNull();
    expect(lateMinutes(day, 8 * 60 + 30)).toBeNull();
  });

  it('marca retardo pasada la tolerancia', () => {
    expect(lateMinutes(day, 9 * 60 + 11)).toBe(11);
    expect(
      scheduleIssue({ isEntry: true, minuteOfDay: 10 * 60 + 5, schedule: day }),
    ).toBe('Retardo de 1 h 5 min (entrada 09:00, Almacén).');
  });

  it('salida anticipada y salida a tiempo', () => {
    expect(
      scheduleIssue({
        isEntry: false,
        minuteOfDay: 17 * 60 + 30,
        schedule: day,
      }),
    ).toBe('Salida anticipada por 30 min (salida 18:00, Almacén).');
    expect(
      scheduleIssue({
        isEntry: false,
        minuteOfDay: 18 * 60 + 5,
        schedule: day,
      }),
    ).toBeNull();
  });

  it('turno que cruza la medianoche', () => {
    expect(lateMinutes(night, 21 * 60 + 50)).toBeNull();
    expect(lateMinutes(night, 15)).toBe(135);
    expect(
      scheduleIssue({ isEntry: false, minuteOfDay: 5 * 60, schedule: night }),
    ).toBe('Salida anticipada por 1 h (salida 06:00, Almacén).');
    expect(
      scheduleIssue({
        isEntry: false,
        minuteOfDay: 6 * 60 + 30,
        schedule: night,
      }),
    ).toBeNull();
  });

  it('sin departamento siempre deja nota', () => {
    expect(
      scheduleIssue({ isEntry: true, minuteOfDay: 540, schedule: null }),
    ).toContain('Sin departamento');
  });

  it('calcula el día y la hora en la zona de la empresa', () => {
    // 2026-11-05 03:30 UTC = 2026-11-04 21:30 en Ciudad de México (UTC-6).
    expect(
      localTime(new Date('2026-11-05T03:30:00Z'), 'America/Mexico_City'),
    ).toEqual({ day: '2026-11-04', minuteOfDay: 21 * 60 + 30 });
  });
});
