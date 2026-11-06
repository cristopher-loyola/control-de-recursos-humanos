import 'dart:typed_data';

import '../database/local_database.dart';
import '../departments/schedule.dart';
import 'pin_store.dart';
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

/// Una entrada sin salida deja de estar abierta pasado este tiempo: queda
/// como jornada incompleta para RH y el empleado puede volver a entrar.
const openEntryLimit = Duration(hours: 18);

AttendanceKind _expected(String? lastKind, DateTime? lastAt, DateTime now) =>
    lastKind == 'entry' && now.difference(lastAt!) < openEntryLimit
    ? AttendanceKind.exit
    : AttendanceKind.entry;

/// Liga la foto cifrada a su checada: no se puede pasar a otra.
String attendancePhotoContext(int eventId) => 'attendance-photo:v1:$eventId';

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
    this.photoCipher,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final LocalDatabase database;
  final void Function() authorizeRecord;

  /// Cifra la foto de las checadas con PIN.
  final TemplateCipher? photoCipher;
  final DateTime Function() _clock;

  Future<AttendanceKind?> nextFor(String number) async {
    final last = await lastFor(number);
    final now = _clock().toLocal();
    final next = _expected(last?.kind.value, last?.occurredAt, now);
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

  /// Checada con PIN cuando el rostro no se reconoce: siempre va a revisión
  /// de RH con la foto tomada en el checador, si la cámara respondió.
  Future<void> recordPin(
    PinCheck check,
    AttendanceKind kind, {
    Uint8List? photo,
  }) => _record(check.employeeNumber, kind, pin: check, photo: photo);

  Future<void> _record(
    String number,
    AttendanceKind kind, {
    FaceMatch? match,
    PinCheck? pin,
    Uint8List? photo,
  }) async {
    if (match == null && pin == null) authorizeRecord();
    if (photo != null && photoCipher == null) {
      throw StateError('No hay cifrado disponible para la foto.');
    }
    final db = await database.open();
    await db.transaction((txn) async {
      if (pin != null) {
        pin.claim(_clock().toUtc());
      } else if (match == null) {
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
      final expected = _expected(
        last?['kind'] as String?,
        last == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                last['occurred_at'] as int,
                isUtc: true,
              ),
        _clock(),
      );
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
      final departments = await txn.rawQuery(
        '''
        SELECT d.name, d.entry_minutes, d.exit_minutes, d.tolerance_minutes
        FROM employees e JOIN departments d ON d.id = e.department_id
        WHERE e.number = ?
        ''',
        [number],
      );
      final department = departments.isEmpty ? null : departments.single;
      final issue = scheduleIssue(
        isEntry: kind == AttendanceKind.entry,
        localTime: now.toLocal(),
        schedule: department == null
            ? null
            : DepartmentSchedule(
                departmentName: department['name'] as String,
                entryMinutes: department['entry_minutes'] as int,
                exitMinutes: department['exit_minutes'] as int,
                toleranceMinutes: department['tolerance_minutes'] as int,
              ),
      );
      final note = pin == null
          ? issue
          : [
              'Checada con PIN: no se reconoció el rostro.',
              if (photo == null) 'Sin foto: la cámara no respondió.',
              ?issue,
            ].join(' ');
      final eventId = await txn.insert('attendance_events', {
        'employee_number': number,
        'kind': kind.value,
        'occurred_at': now.millisecondsSinceEpoch,
        'capture_method': match != null
            ? 'facial'
            : pin != null
            ? 'pin'
            : 'manual',
        'similarity': match?.score,
        'identity_model': match == null ? null : FaceEngine.modelId,
        // Sin prueba de vida hasta integrar un modelo antisuplantación.
        'liveness_method': match == null ? null : 'none',
        'schedule_note': note,
      });
      if (photo != null) {
        await txn.insert('attendance_photos', {
          'event_id': eventId,
          'encrypted_jpeg': await photoCipher!.seal(
            photo,
            attendancePhotoContext(eventId),
          ),
          'captured_at': now.millisecondsSinceEpoch,
        });
      }
      // Solo lo que sale del horario llega a RH; las manuales siempre se revisan.
      if (match != null && issue == null) {
        await txn.insert('attendance_reviews', {
          'event_id': eventId,
          'decision': 'approved',
          'reviewer': 'sistema',
          'reason': 'A tiempo según el horario de ${department!['name']}.',
          'reviewed_at': now.millisecondsSinceEpoch,
        });
      }
    });
  }
}
