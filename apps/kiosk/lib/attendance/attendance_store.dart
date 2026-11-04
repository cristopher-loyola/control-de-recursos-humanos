import '../database/local_database.dart';
import '../vision/face_engine.dart';
import '../vision/face_template_store.dart';
import '../vision/face_matching.dart';

enum AttendanceKind {
  entry('entry', 'Entrada'),
  exit('exit', 'Salida');

  const AttendanceKind(this.value, this.label);
  final String value;
  final String label;
}

class AttendanceRuleError implements Exception {
  const AttendanceRuleError(this.message);
  final String message;
}

class AttendanceEvent {
  const AttendanceEvent({
    required this.employeeNumber,
    required this.employeeName,
    required this.kind,
    required this.occurredAt,
  });
  final String employeeNumber;
  final String employeeName;
  final AttendanceKind kind;
  final DateTime occurredAt;

  factory AttendanceEvent.fromRow(Map<String, Object?> row) => AttendanceEvent(
    employeeNumber: row['employee_number'] as String,
    employeeName: row['employee_name'] as String,
    kind: AttendanceKind.values.firstWhere((kind) => kind.value == row['kind']),
    occurredAt: DateTime.fromMillisecondsSinceEpoch(
      row['occurred_at'] as int,
      isUtc: true,
    ),
  );
}

class AttendanceStore {
  AttendanceStore(
    this.database, {
    required this.authorizeRecord,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final LocalDatabase database;
  final void Function() authorizeRecord;
  final DateTime Function() _clock;

  Future<AttendanceKind?> nextFor(String number) async {
    final last = await lastFor(number);
    final next = last?.kind == AttendanceKind.entry
        ? AttendanceKind.exit
        : AttendanceKind.entry;
    final now = _clock().toLocal();
    final start = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final end = DateTime(
      now.year,
      now.month,
      now.day + 1,
    ).millisecondsSinceEpoch;
    final rows = await (await database.open()).query(
      'attendance_events',
      columns: ['id'],
      where: 'employee_number = ? AND kind = ? AND occurred_at >= ? AND occurred_at < ?',
      whereArgs: [number, next.value, start, end],
      limit: 1,
    );
    return rows.isEmpty ? next : null;
  }

  Future<AttendanceEvent?> lastFor(String number) async {
    final rows = await (await database.open()).rawQuery(
      '''
      SELECT a.*, e.name AS employee_name
      FROM attendance_events a JOIN employees e ON e.number = a.employee_number
      WHERE a.employee_number = ? ORDER BY a.id DESC LIMIT 1
    ''',
      [number],
    );
    return rows.isEmpty ? null : AttendanceEvent.fromRow(rows.single);
  }

  Future<List<AttendanceEvent>> forDay(DateTime day) async {
    final local = day.toLocal();
    final start = DateTime(local.year, local.month, local.day).toUtc();
    final end = DateTime(local.year, local.month, local.day + 1).toUtc();
    final rows = await (await database.open()).rawQuery(
      '''
      SELECT a.*, e.name AS employee_name
      FROM attendance_events a JOIN employees e ON e.number = a.employee_number
      WHERE a.occurred_at >= ? AND a.occurred_at < ? ORDER BY a.id DESC
    ''',
      [start.millisecondsSinceEpoch, end.millisecondsSinceEpoch],
    );
    return rows.map(AttendanceEvent.fromRow).toList();
  }

  Future<void> record(String number, AttendanceKind kind) =>
      _record(number, kind);

  Future<void> recordFacial(FaceMatch match, AttendanceKind kind) =>
      _record(match.employeeNumber, kind, match: match);

  Future<void> _record(
    String number,
    AttendanceKind kind, {
    FaceMatch? match,
  }) async {
    if (match == null) authorizeRecord();
    final db = await database.open();
    await db.transaction((txn) async {
      if (match == null) {
        authorizeRecord();
      } else {
        match.claim(_clock().toUtc());
        final valid = await txn.rawQuery(
          '''
          SELECT t.id FROM face_templates t JOIN consent_records c ON c.id = t.consent_id
          WHERE t.id = ? AND t.employee_number = ? AND t.consent_id = ?
          AND c.kind = 'recorded' AND c.id = (
            SELECT id FROM consent_records WHERE employee_number = ? ORDER BY id DESC LIMIT 1
          )
        ''',
          [match.templateId, number, match.consentId, number],
        );
        if (valid.isEmpty) {
          throw const FaceRuleError(
            'El registro facial ya no está vigente. Solicita apoyo a RH.',
          );
        }
      }
      final employees = await txn.query(
        'employees',
        columns: ['number'],
        where: 'number = ?',
        whereArgs: [number],
        limit: 1,
      );
      if (employees.isEmpty) {
        throw const AttendanceRuleError(
          'El empleado ya no está disponible. Actualiza la lista.',
        );
      }
      final previous = await txn.query(
        'attendance_events',
        where: 'employee_number = ?',
        whereArgs: [number],
        orderBy: 'id DESC',
        limit: 1,
      );
      final last = previous.isEmpty ? null : previous.single;
      final expected = last?['kind'] == 'entry'
          ? AttendanceKind.exit
          : AttendanceKind.entry;
      if (kind != expected) {
        throw AttendanceRuleError(
          expected == AttendanceKind.entry
              ? 'Primero registra una entrada.'
              : 'Ya hay una entrada abierta. Registra la salida.',
        );
      }
      final now = _clock().toUtc();
      final localDay = now.toLocal();
      final dayStart = DateTime(
        localDay.year,
        localDay.month,
        localDay.day,
      ).toUtc();
      final dayEnd = DateTime(
        localDay.year,
        localDay.month,
        localDay.day + 1,
      ).toUtc();
      final existingToday = await txn.query(
        'attendance_events',
        columns: ['id'],
        where: 'employee_number = ? AND kind = ? AND occurred_at >= ? AND occurred_at < ?',
        whereArgs: [
          number,
          kind.value,
          dayStart.millisecondsSinceEpoch,
          dayEnd.millisecondsSinceEpoch,
        ],
        limit: 1,
      );
      if (existingToday.isNotEmpty) {
        throw AttendanceRuleError(
          'Este empleado ya tiene una ${kind.label.toLowerCase()} registrada hoy.',
        );
      }
      if (last != null &&
          now.millisecondsSinceEpoch < (last['occurred_at'] as int)) {
        throw const AttendanceRuleError(
          'La hora de la tablet es anterior al último movimiento. Revisa el reloj.',
        );
      }
      await txn.insert('attendance_events', {
        'employee_number': number,
        'kind': kind.value,
        'occurred_at': now.millisecondsSinceEpoch,
        'capture_method': match == null ? 'manual' : 'facial',
        'similarity': match?.score,
        'identity_model': match == null ? null : FaceEngine.modelId,
        'liveness_method': match == null ? null : 'blink_challenge_v1',
      });
    });
  }
}
