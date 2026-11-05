import '../audit/audit_store.dart';
import '../database/local_database.dart';
import '../payroll/payroll_store.dart' show isPayrollClosed;

enum ReviewDecision {
  approved('approved', 'Aprobada'),
  rejected('rejected', 'Rechazada');

  const ReviewDecision(this.value, this.label);
  final String value;
  final String label;
}

class ReviewRuleError implements Exception {
  const ReviewRuleError(this.message);
  final String message;
}

class AttendanceReviewItem {
  const AttendanceReviewItem({
    required this.eventId,
    required this.employeeNumber,
    required this.employeeName,
    required this.kind,
    required this.occurredAt,
    this.decision,
    this.reviewer,
    this.reason,
    this.reviewedAt,
    this.captureMethod = 'manual',
    this.scheduleNote,
  });

  final int eventId;
  final String captureMethod;

  /// Por qué llegó a revisión según el horario del departamento.
  final String? scheduleNote;
  final String employeeNumber;
  final String employeeName;
  final String kind;
  final DateTime occurredAt;
  final ReviewDecision? decision;
  final String? reviewer;
  final String? reason;
  final DateTime? reviewedAt;

  factory AttendanceReviewItem.fromRow(Map<String, Object?> row) {
    final value = row['decision'] as String?;
    return AttendanceReviewItem(
      eventId: row['id'] as int,
      captureMethod: row['capture_method'] as String? ?? 'manual',
      scheduleNote: row['schedule_note'] as String?,
      employeeNumber: row['employee_number'] as String,
      employeeName: row['employee_name'] as String,
      kind: row['kind'] as String,
      occurredAt: DateTime.fromMillisecondsSinceEpoch(
        row['occurred_at'] as int,
        isUtc: true,
      ),
      decision: value == null
          ? null
          : ReviewDecision.values.firstWhere((item) => item.value == value),
      reviewer: row['reviewer'] as String?,
      reason: row['reason'] as String?,
      reviewedAt: row['reviewed_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              row['reviewed_at'] as int,
              isUtc: true,
            ),
    );
  }
}

class AttendanceReviewStore {
  AttendanceReviewStore(
    this.database, {
    required this.authorize,
    required this.actor,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LocalDatabase database;
  final void Function() authorize;
  final String Function() actor;
  final DateTime Function() _clock;

  Future<List<AttendanceReviewItem>> forDay(DateTime day) async {
    authorize();
    final local = day.toLocal();
    final start = DateTime(local.year, local.month, local.day).toUtc();
    final end = DateTime(local.year, local.month, local.day + 1).toUtc();
    final db = await database.open();
    return db.transaction((txn) async {
      authorize();
      final rows = await txn.rawQuery(
        '''
        SELECT a.id, a.employee_number, e.name AS employee_name,
               a.kind, a.occurred_at, a.capture_method, a.schedule_note, r.decision, r.reviewer, r.reason,
               r.reviewed_at
        FROM attendance_events a
        JOIN employees e ON e.number = a.employee_number
        LEFT JOIN attendance_reviews r ON r.id = (
          SELECT id FROM attendance_reviews
          WHERE event_id = a.id ORDER BY id DESC LIMIT 1
        )
        WHERE a.occurred_at >= ? AND a.occurred_at < ?
        ORDER BY a.occurred_at DESC, a.id DESC
      ''',
        [start.millisecondsSinceEpoch, end.millisecondsSinceEpoch],
      );
      return rows.map(AttendanceReviewItem.fromRow).toList();
    });
  }

  Future<void> review(
    int eventId,
    ReviewDecision decision,
    String reason,
  ) async {
    authorize();
    final trimmedReason = reason.trim();
    if (trimmedReason.length < 10 || trimmedReason.length > 500) {
      throw const ReviewRuleError('Escribe un motivo de 10 a 500 caracteres.');
    }
    final reviewer = actor().trim();
    if (reviewer.length < 3 || reviewer.length > 100) {
      throw const ReviewRuleError('No se identificó al responsable.');
    }
    final db = await database.open();
    await db.transaction((txn) async {
      authorize();
      final events = await txn.query(
        'attendance_events',
        columns: ['id', 'occurred_at'],
        where: 'id = ?',
        whereArgs: [eventId],
        limit: 1,
      );
      if (events.isEmpty) {
        throw const ReviewRuleError('La checada ya no está disponible.');
      }
      final occurredAt = DateTime.fromMillisecondsSinceEpoch(
        events.single['occurred_at'] as int,
        isUtc: true,
      );
      if (await isPayrollClosed(txn, occurredAt)) {
        throw const ReviewRuleError(
          'La pre-nómina de ese día ya está cerrada. Pide al administrador que la reabra.',
        );
      }
      final previous = await txn.query(
        'attendance_reviews',
        columns: ['id'],
        where: 'event_id = ?',
        whereArgs: [eventId],
        limit: 1,
      );
      if (previous.isNotEmpty) {
        throw const ReviewRuleError('Esta checada ya fue revisada.');
      }
      final now = _clock().toUtc();
      await txn.insert('attendance_reviews', {
        'event_id': eventId,
        'decision': decision.value,
        'reviewer': reviewer,
        'reason': trimmedReason,
        'reviewed_at': now.millisecondsSinceEpoch,
      });
      await writeAudit(
        txn,
        action: AuditAction.attendanceReviewed,
        actor: reviewer,
        time: now,
        details: {'eventId': eventId, 'decision': decision.value},
      );
    });
  }
}
