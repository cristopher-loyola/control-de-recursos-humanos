/// Horario de un departamento, en minutos desde la medianoche.
class DepartmentSchedule {
  const DepartmentSchedule({
    required this.departmentName,
    required this.entryMinutes,
    required this.exitMinutes,
    required this.toleranceMinutes,
  });
  final String departmentName;
  final int entryMinutes;
  final int exitMinutes;
  final int toleranceMinutes;
}

/// Días laborables guardados como bits (lunes = 1, martes = 2 … domingo = 64).
abstract final class WorkDays {
  static const mondayToFriday = 31;
  static const mondayToSaturday = 63;
  static const letters = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];
  static const names = [
    'lunes',
    'martes',
    'miércoles',
    'jueves',
    'viernes',
    'sábado',
    'domingo',
  ];

  static bool includes(int days, DateTime date) =>
      days & (1 << (date.weekday - 1)) != 0;

  static String describe(int days) {
    if (days == mondayToFriday) return 'lunes a viernes';
    if (days == mondayToSaturday) return 'lunes a sábado';
    if (days == 127) return 'todos los días';
    return [
      for (var i = 0; i < 7; i++)
        if (days & (1 << i) != 0) letters[i],
    ].join(' ');
  }
}

/// Minutos de retraso respecto a la hora de entrada, o null si llegó a
/// tiempo (antes de la hora o dentro de la tolerancia).
int? lateMinutes(DepartmentSchedule schedule, DateTime localTime) {
  final now = localTime.hour * 60 + localTime.minute;
  final late = (now - schedule.entryMinutes) % 1440;
  return late > schedule.toleranceMinutes && late < 720 ? late : null;
}

String formatMinutes(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

/// Devuelve por qué una checada debe revisarla RH, o null si fue a tiempo.
///
/// Se mide la distancia más corta en el reloj de 24 horas, así un turno que
/// cruza la medianoche (22:00 a 06:00) se evalúa igual que uno de día. Una
/// diferencia de más de 12 horas se toma como "antes de la hora", no "después".
String? scheduleIssue({
  required bool isEntry,
  required DateTime localTime,
  required DepartmentSchedule? schedule,
}) {
  if (schedule == null) {
    return 'Sin departamento asignado: no hay horario para comparar.';
  }
  final now = localTime.hour * 60 + localTime.minute;
  if (isEntry) {
    final late = lateMinutes(schedule, localTime);
    return late == null
        ? null
        : 'Retardo de ${formatDuration(late)} (entrada ${formatMinutes(schedule.entryMinutes)}, ${schedule.departmentName}).';
  }
  final early = (schedule.exitMinutes - now) % 1440;
  if (early > 0 && early < 720) {
    return 'Salida anticipada por ${formatDuration(early)} (salida ${formatMinutes(schedule.exitMinutes)}, ${schedule.departmentName}).';
  }
  return null;
}

String formatDuration(int minutes) {
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours h' : '$hours h $rest min';
}
