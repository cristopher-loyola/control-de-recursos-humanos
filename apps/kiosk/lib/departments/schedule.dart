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
    final late = (now - schedule.entryMinutes) % 1440;
    if (late > schedule.toleranceMinutes && late < 720) {
      return 'Retardo de ${_duration(late)} (entrada ${formatMinutes(schedule.entryMinutes)}, ${schedule.departmentName}).';
    }
    return null;
  }
  final early = (schedule.exitMinutes - now) % 1440;
  if (early > 0 && early < 720) {
    return 'Salida anticipada por ${_duration(early)} (salida ${formatMinutes(schedule.exitMinutes)}, ${schedule.departmentName}).';
  }
  return null;
}

String _duration(int minutes) {
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours h' : '$hours h $rest min';
}
