import { describe, expect, it } from 'vitest';
import { officialHolidays } from './official.js';

describe('Descansos obligatorios LFT art. 74 (iguales a la tablet)', () => {
  it('lunes movibles de febrero, marzo y noviembre', () => {
    expect(officialHolidays(2026).map((h) => h.day)).toEqual([
      '2026-01-01',
      '2026-02-02',
      '2026-03-16',
      '2026-05-01',
      '2026-09-16',
      '2026-11-16',
      '2026-12-25',
    ]);
  });

  it('transmisión del Poder Ejecutivo cada 6 años', () => {
    expect(officialHolidays(2030).map((h) => h.day)).toContain('2030-10-01');
    expect(officialHolidays(2027).map((h) => h.day)).not.toContain(
      '2027-10-01',
    );
  });
});
