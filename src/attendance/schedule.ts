// La app de la tablet aplica estas mismas reglas sin red: la tablet y el
// servidor deben dar la misma nota de horario para la misma checada.

export interface DepartmentSchedule {
  departmentName: string;
  entryMinutes: number;
  exitMinutes: number;
  toleranceMinutes: number;
}

/** Módulo con resultado no negativo, como `%` de Dart. */
function mod(value: number, divisor: number): number {
  return ((value % divisor) + divisor) % divisor;
}

export function formatMinutes(minutes: number): string {
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${pad(Math.floor(minutes / 60))}:${pad(minutes % 60)}`;
}

export function formatDuration(minutes: number): string {
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  return rest === 0 ? `${hours} h` : `${hours} h ${rest} min`;
}

/** Minutos de retraso, o null si llegó a tiempo o dentro de la tolerancia. */
export function lateMinutes(
  schedule: DepartmentSchedule,
  minuteOfDay: number,
): number | null {
  const late = mod(minuteOfDay - schedule.entryMinutes, 1440);
  return late > schedule.toleranceMinutes && late < 720 ? late : null;
}

/** Por qué RH debe revisar la checada, o null si fue a tiempo. */
export function scheduleIssue(input: {
  isEntry: boolean;
  minuteOfDay: number;
  schedule: DepartmentSchedule | null;
}): string | null {
  const { schedule, minuteOfDay } = input;
  if (!schedule) {
    return 'Sin departamento asignado: no hay horario para comparar.';
  }
  if (input.isEntry) {
    const late = lateMinutes(schedule, minuteOfDay);
    return late === null
      ? null
      : `Retardo de ${formatDuration(late)} (entrada ${formatMinutes(schedule.entryMinutes)}, ${schedule.departmentName}).`;
  }
  const early = mod(schedule.exitMinutes - minuteOfDay, 1440);
  if (early > 0 && early < 720) {
    return `Salida anticipada por ${formatDuration(early)} (salida ${formatMinutes(schedule.exitMinutes)}, ${schedule.departmentName}).`;
  }
  return null;
}

export interface LocalTime {
  /** AAAA-MM-DD en la zona de la empresa. */
  day: string;
  minuteOfDay: number;
}

/** Fecha y minuto del día de un instante en la zona horaria de la empresa. */
export function localTime(instant: Date, timeZone: string): LocalTime {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-CA', {
      timeZone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      hourCycle: 'h23',
    })
      .formatToParts(instant)
      .map((part) => [part.type, part.value]),
  );
  return {
    day: `${parts.year}-${parts.month}-${parts.day}`,
    minuteOfDay: Number(parts.hour) * 60 + Number(parts.minute),
  };
}
