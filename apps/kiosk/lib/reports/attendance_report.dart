import '../departments/schedule.dart';

enum ReportPeriod { day, week, month }

/// Rango de fechas locales [start, end) que cubre el periodo de [anchor].
({DateTime start, DateTime end}) periodRange(
  ReportPeriod period,
  DateTime anchor,
) {
  final day = DateTime(anchor.year, anchor.month, anchor.day);
  return switch (period) {
    ReportPeriod.day => (
      start: day,
      end: DateTime(day.year, day.month, day.day + 1),
    ),
    ReportPeriod.week => (
      start: DateTime(day.year, day.month, day.day - (day.weekday - 1)),
      end: DateTime(day.year, day.month, day.day - (day.weekday - 1) + 7),
    ),
    ReportPeriod.month => (
      start: DateTime(day.year, day.month),
      end: DateTime(day.year, day.month + 1),
    ),
  };
}

/// Mueve el ancla un periodo hacia atrás (-1) o adelante (+1).
DateTime shiftPeriod(ReportPeriod period, DateTime anchor, int step) =>
    switch (period) {
      ReportPeriod.day => DateTime(
        anchor.year,
        anchor.month,
        anchor.day + step,
      ),
      ReportPeriod.week => DateTime(
        anchor.year,
        anchor.month,
        anchor.day + 7 * step,
      ),
      ReportPeriod.month => DateTime(anchor.year, anchor.month + step),
    };

class ReportEmployee {
  const ReportEmployee({
    required this.number,
    required this.name,
    this.departmentId,
    this.registeredAt,
  });
  final String number;
  final String name;
  final int? departmentId;

  /// Fecha de alta; sin ella se cuenta todo el periodo.
  final DateTime? registeredAt;
}

class ReportDepartment {
  const ReportDepartment({
    required this.id,
    required this.schedule,
    required this.workDays,
  });
  final int id;
  final DepartmentSchedule schedule;
  final int workDays;
}

/// Día festivo o descanso autorizado; sin departamento aplica a todos.
class ReportHoliday {
  const ReportHoliday({
    required this.day,
    required this.name,
    this.departmentId,
  });
  final DateTime day;
  final String name;
  final int? departmentId;

  bool appliesTo(int? department) =>
      departmentId == null || departmentId == department;
}

enum DayStatus { onTime, late, absent, pending, notScheduled }

class DayResult {
  const DayResult(this.day, this.status, {this.entryAt, this.lateBy});
  final DateTime day;
  final DayStatus status;
  final DateTime? entryAt;
  final int? lateBy;
}

class EmployeeSummary {
  EmployeeSummary(this.employee, this.departmentName, this.days);
  final ReportEmployee employee;
  final String? departmentName;

  /// Un resultado por cada día laborable del periodo, hasta hoy.
  final List<DayResult> days;

  int count(DayStatus status) => days.where((d) => d.status == status).length;
  int get workDays => days.where((d) => d.status != DayStatus.pending).length;
  int get attended => count(DayStatus.onTime) + count(DayStatus.late);
  int get onTime => count(DayStatus.onTime);
  int get late => count(DayStatus.late);
  int get absent => count(DayStatus.absent);
  int get lateMinutes =>
      days.fold(0, (total, day) => total + (day.lateBy ?? 0));
  bool get hasSchedule => departmentName != null;
}

/// Clasifica cada día laborable de cada empleado según su primera entrada.
///
/// - A tiempo: entró antes de la hora o dentro de la tolerancia.
/// - Tarde: entró después de la tolerancia.
/// - Falta: no hay entrada en un día laborable ya transcurrido.
/// - Pendiente: es hoy y todavía no se cumple su hora más la tolerancia.
/// Los días de descanso, los festivos, los futuros y los anteriores al alta
/// no cuentan; si alguien trabajó en festivo, su entrada sí se registra.
List<EmployeeSummary> buildReport({
  required List<ReportEmployee> employees,
  required List<ReportDepartment> departments,
  required Map<String, List<DateTime>> entries,
  required DateTime start,
  required DateTime end,
  required DateTime now,
  List<ReportHoliday> holidays = const [],
}) {
  final byId = {for (final d in departments) d.id: d};
  final today = DateTime(now.year, now.month, now.day);
  final summaries = <EmployeeSummary>[];
  for (final employee in employees) {
    final department = byId[employee.departmentId];
    if (department == null) {
      summaries.add(EmployeeSummary(employee, null, const []));
      continue;
    }
    final firstEntry = <DateTime, DateTime>{};
    for (final at in entries[employee.number] ?? const <DateTime>[]) {
      final local = at.toLocal();
      firstEntry.putIfAbsent(
        DateTime(local.year, local.month, local.day),
        () => local,
      );
    }
    final registered = employee.registeredAt?.toLocal();
    final from = registered == null
        ? start
        : DateTime(registered.year, registered.month, registered.day);
    final days = <DayResult>[];
    for (
      var day = start;
      day.isBefore(end) && !day.isAfter(today);
      day = DateTime(day.year, day.month, day.day + 1)
    ) {
      if (day.isBefore(from) || !WorkDays.includes(department.workDays, day)) {
        continue;
      }
      final entry = firstEntry[day];
      final holiday = holidays.any(
        (h) => h.day == day && h.appliesTo(employee.departmentId),
      );
      if (holiday && entry == null) continue;
      if (entry != null) {
        final late = lateMinutes(department.schedule, entry);
        days.add(
          DayResult(
            day,
            late == null ? DayStatus.onTime : DayStatus.late,
            entryAt: entry,
            lateBy: late,
          ),
        );
        continue;
      }
      final limit =
          department.schedule.entryMinutes +
          department.schedule.toleranceMinutes;
      final waiting = day == today && now.hour * 60 + now.minute <= limit;
      days.add(DayResult(day, waiting ? DayStatus.pending : DayStatus.absent));
    }
    summaries.add(
      EmployeeSummary(employee, department.schedule.departmentName, days),
    );
  }
  summaries.sort(
    (a, b) =>
        a.employee.name.toLowerCase().compareTo(b.employee.name.toLowerCase()),
  );
  return summaries;
}
