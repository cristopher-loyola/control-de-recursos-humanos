import '../database/local_database.dart';
import '../departments/schedule.dart';
import 'attendance_report.dart';

class ReportData {
  const ReportData({
    required this.summaries,
    required this.departments,
    required this.pendingReviews,
    required this.withoutFace,
  });
  final List<EmployeeSummary> summaries;

  /// Para el filtro: id y nombre de cada departamento.
  final List<({int id, String name})> departments;
  final int pendingReviews;
  final int withoutFace;
}

/// Lee de la base lo necesario para el tablero de asistencia.
class ReportStore {
  ReportStore(
    this.database, {
    required this.authorize,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final LocalDatabase database;
  final void Function() authorize;
  final DateTime Function() _clock;

  Future<ReportData> load({
    required DateTime start,
    required DateTime end,
    int? departmentId,
    bool withoutDepartment = false,
  }) async {
    authorize();
    final db = await database.open();
    final from = start.toUtc().millisecondsSinceEpoch;
    final to = end.toUtc().millisecondsSinceEpoch;
    return db.transaction((txn) async {
      authorize();
      final departmentRows = await txn.query(
        'departments',
        orderBy: 'name COLLATE NOCASE',
      );
      final departments = [
        for (final row in departmentRows)
          ReportDepartment(
            id: row['id'] as int,
            workDays: row['work_days'] as int,
            schedule: DepartmentSchedule(
              departmentName: row['name'] as String,
              entryMinutes: row['entry_minutes'] as int,
              exitMinutes: row['exit_minutes'] as int,
              toleranceMinutes: row['tolerance_minutes'] as int,
            ),
          ),
      ];
      final where = withoutDepartment
          ? 'WHERE e.department_id IS NULL'
          : departmentId == null
          ? ''
          : 'WHERE e.department_id = ?';
      final employeeRows = await txn.rawQuery(
        '''
        SELECT e.number, e.name, e.department_id, e.registered_at,
               EXISTS(SELECT 1 FROM face_templates t WHERE t.employee_number = e.number) AS has_face
        FROM employees e $where
        ''',
        [?departmentId],
      );
      // Una checada rechazada por RH no cuenta como asistencia.
      final entryRows = await txn.rawQuery(
        '''
        SELECT a.employee_number, a.occurred_at FROM attendance_events a
        WHERE a.kind = 'entry' AND a.occurred_at >= ? AND a.occurred_at < ?
          AND COALESCE((SELECT decision FROM attendance_reviews r
                        WHERE r.event_id = a.id ORDER BY r.id DESC LIMIT 1), '') <> 'rejected'
        ORDER BY a.occurred_at
        ''',
        [from, to],
      );
      final pending = await txn.rawQuery(
        '''
        SELECT count(*) AS n FROM attendance_events a
        WHERE a.occurred_at >= ? AND a.occurred_at < ?
          AND NOT EXISTS (SELECT 1 FROM attendance_reviews r WHERE r.event_id = a.id)
        ''',
        [from, to],
      );
      final entries = <String, List<DateTime>>{};
      for (final row in entryRows) {
        entries
            .putIfAbsent(row['employee_number'] as String, () => [])
            .add(
              DateTime.fromMillisecondsSinceEpoch(
                row['occurred_at'] as int,
                isUtc: true,
              ),
            );
      }
      final employees = [
        for (final row in employeeRows)
          ReportEmployee(
            number: row['number'] as String,
            name: row['name'] as String,
            departmentId: row['department_id'] as int?,
            registeredAt: row['registered_at'] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    row['registered_at'] as int,
                    isUtc: true,
                  ),
          ),
      ];
      return ReportData(
        summaries: buildReport(
          employees: employees,
          departments: departments,
          entries: entries,
          start: start,
          end: end,
          now: _clock(),
        ),
        departments: [
          for (final d in departments)
            (id: d.id, name: d.schedule.departmentName),
        ],
        pendingReviews: pending.single['n'] as int,
        withoutFace: employeeRows.where((row) => row['has_face'] != 1).length,
      );
    });
  }
}
