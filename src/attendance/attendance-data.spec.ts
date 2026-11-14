import { countsFrom } from './attendance-data';

describe('desde cuándo se mide la asistencia', () => {
  const today = '2026-11-13';

  it('no cuenta los días antes de que la sucursal empezara a checar', () => {
    expect(
      countsFrom({
        hiredOn: '2020-06-01',
        registeredOn: '2026-10-01',
        branchStart: '2026-10-20',
        today,
      }),
    ).toBe('2026-10-20');
  });

  it('ni antes de que el empleado se registrara en el sistema', () => {
    expect(
      countsFrom({
        hiredOn: '2020-06-01',
        registeredOn: '2026-11-03',
        branchStart: '2026-10-20',
        today,
      }),
    ).toBe('2026-11-03');
  });

  it('ni antes de su fecha de ingreso', () => {
    expect(
      countsFrom({
        hiredOn: '2026-11-10',
        registeredOn: '2026-11-03',
        branchStart: '2026-10-20',
        today,
      }),
    ).toBe('2026-11-10');
  });

  it('una sucursal sin checadas todavía no tiene nada que medir', () => {
    expect(
      countsFrom({
        hiredOn: '2020-06-01',
        registeredOn: '2026-10-01',
        branchStart: null,
        today,
      }),
    ).toBe('2026-11-14');
  });
});
