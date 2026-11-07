// Descansos obligatorios de la Ley Federal del Trabajo (art. 74), los mismos que
// agrega la app de la tablet. Las jornadas electorales se agregan a mano.

function day(year: number, month: number, date: number): string {
  return `${year}-${String(month).padStart(2, '0')}-${String(date).padStart(2, '0')}`;
}

/** n-ésimo lunes del mes (1 = primero). */
function nthMonday(year: number, month: number, n: number): string {
  const weekday = new Date(Date.UTC(year, month - 1, 1)).getUTCDay();
  const offset = (8 - weekday) % 7;
  return day(year, month, 1 + offset + 7 * (n - 1));
}

export function officialHolidays(
  year: number,
): { day: string; name: string }[] {
  return [
    { day: day(year, 1, 1), name: 'Año Nuevo' },
    { day: nthMonday(year, 2, 1), name: 'Día de la Constitución' },
    { day: nthMonday(year, 3, 3), name: 'Natalicio de Benito Juárez' },
    { day: day(year, 5, 1), name: 'Día del Trabajo' },
    { day: day(year, 9, 16), name: 'Día de la Independencia' },
    ...((year - 2024) % 6 === 0
      ? [{ day: day(year, 10, 1), name: 'Transmisión del Poder Ejecutivo' }]
      : []),
    { day: nthMonday(year, 11, 3), name: 'Día de la Revolución' },
    { day: day(year, 12, 25), name: 'Navidad' },
  ];
}
