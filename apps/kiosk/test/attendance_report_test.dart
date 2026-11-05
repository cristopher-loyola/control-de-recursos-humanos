import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/departments/schedule.dart';
import 'package:kiosk/reports/attendance_report.dart';

void main() {
  const production = ReportDepartment(
    id: 1,
    workDays: WorkDays.mondayToFriday,
    schedule: DepartmentSchedule(
      departmentName: 'Producción',
      entryMinutes: 8 * 60,
      exitMinutes: 17 * 60,
      toleranceMinutes: 10,
    ),
  );
  const ana = ReportEmployee(number: '1', name: 'Ana', departmentId: 1);
  const luis = ReportEmployee(number: '2', name: 'Luis', departmentId: 1);
  const sinDepto = ReportEmployee(number: '3', name: 'Sara');

  // Lunes 2 de noviembre de 2026.
  final monday = DateTime(2026, 11, 2);

  List<EmployeeSummary> report({
    required DateTime start,
    required DateTime end,
    required DateTime now,
    Map<String, List<DateTime>> entries = const {},
    List<ReportEmployee> employees = const [ana, luis, sinDepto],
  }) => buildReport(
    employees: employees,
    departments: const [production],
    entries: entries,
    start: start,
    end: end,
    now: now,
  );

  test('Día: clasifica a tiempo, tarde y falta', () {
    final r = report(
      start: monday,
      end: DateTime(2026, 11, 3),
      now: DateTime(2026, 11, 2, 18),
      entries: {
        '1': [DateTime(2026, 11, 2, 8, 9)],
      },
      employees: const [ana, luis],
    );
    expect(r[0].days.single.status, DayStatus.onTime);
    expect(r[1].days.single.status, DayStatus.absent);

    final late = report(
      start: monday,
      end: DateTime(2026, 11, 3),
      now: DateTime(2026, 11, 2, 18),
      entries: {
        '2': [DateTime(2026, 11, 2, 8, 25), DateTime(2026, 11, 2, 13)],
      },
      employees: const [luis],
    );
    expect(late.single.days.single.status, DayStatus.late);
    expect(
      late.single.days.single.lateBy,
      25,
      reason: 'Cuenta la primera entrada del día.',
    );
  });

  test('Hoy, dentro de la tolerancia, aún no es falta', () {
    final r = report(
      start: monday,
      end: DateTime(2026, 11, 3),
      now: DateTime(2026, 11, 2, 8, 5),
      employees: const [ana],
    );
    expect(r.single.days.single.status, DayStatus.pending);
    expect(r.single.absent, 0);
  });

  test('Semana: descansos, días futuros y antes del alta no cuentan', () {
    final range = periodRange(ReportPeriod.week, DateTime(2026, 11, 5));
    expect(range.start, monday);
    expect(range.end, DateTime(2026, 11, 9));
    final r = report(
      start: range.start,
      end: range.end,
      // Jueves por la tarde: viernes, sábado y domingo aún no cuentan.
      now: DateTime(2026, 11, 5, 18),
      entries: {
        '1': [
          DateTime(2026, 11, 2, 7, 55),
          DateTime(2026, 11, 3, 8, 30),
          DateTime(2026, 11, 5, 8),
        ],
      },
      employees: [
        ana,
        ReportEmployee(
          number: '2',
          name: 'Luis',
          departmentId: 1,
          registeredAt: DateTime(2026, 11, 4, 12),
        ),
        sinDepto,
      ],
    );
    final anaSummary = r.firstWhere((s) => s.employee.number == '1');
    expect(anaSummary.workDays, 4);
    expect(anaSummary.onTime, 2);
    expect(anaSummary.late, 1);
    expect(anaSummary.lateMinutes, 30);
    expect(anaSummary.absent, 1);
    final luisSummary = r.firstWhere((s) => s.employee.number == '2');
    expect(luisSummary.workDays, 2, reason: 'Dado de alta el miércoles.');
    expect(luisSummary.absent, 2);
    final sara = r.firstWhere((s) => s.employee.number == '3');
    expect(sara.hasSchedule, isFalse);
    expect(sara.days, isEmpty);
  });

  test('Mes y navegación entre periodos', () {
    final range = periodRange(ReportPeriod.month, DateTime(2026, 11, 20));
    expect(range.start, DateTime(2026, 11));
    expect(range.end, DateTime(2026, 12));
    expect(
      shiftPeriod(ReportPeriod.month, DateTime(2026, 1, 31), -1),
      DateTime(2025, 12),
    );
    expect(shiftPeriod(ReportPeriod.week, monday, 1), DateTime(2026, 11, 9));
    expect(
      WorkDays.includes(WorkDays.mondayToFriday, DateTime(2026, 11, 7)),
      isFalse,
    );
    expect(WorkDays.describe(WorkDays.mondayToSaturday), 'lunes a sábado');
  });

  test('Festivos: sin checada no cuentan; si trabajó, sí cuenta', () {
    final week = periodRange(ReportPeriod.week, monday);
    final r = report(
      start: week.start,
      end: week.end,
      now: DateTime(2026, 11, 8, 20),
      entries: {
        '2': [DateTime(2026, 11, 2, 8)],
      },
      employees: const [ana, luis],
    );
    expect(
      r.first.absent,
      5,
      reason: 'Sin festivos, Ana falta toda la semana.',
    );
    final withHoliday = buildReport(
      employees: const [ana, luis],
      departments: const [production],
      entries: {
        '2': [DateTime(2026, 11, 2, 8)],
      },
      start: week.start,
      end: week.end,
      now: DateTime(2026, 11, 8, 20),
      holidays: [
        ReportHoliday(day: monday, name: 'Puente'),
        ReportHoliday(
          day: DateTime(2026, 11, 3),
          name: 'Inventario',
          departmentId: 9,
        ),
      ],
    );
    final anaSummary = withHoliday.firstWhere((s) => s.employee.number == '1');
    expect(
      anaSummary.workDays,
      4,
      reason: 'El lunes festivo no cuenta; el del otro departamento sí.',
    );
    expect(anaSummary.absent, 4);
    final luisSummary = withHoliday.firstWhere((s) => s.employee.number == '2');
    expect(
      luisSummary.attended,
      1,
      reason: 'Trabajó en festivo y se registra.',
    );
  });
}
