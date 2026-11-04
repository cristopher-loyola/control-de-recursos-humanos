import 'dart:convert';
import 'dart:typed_data';

class InvalidBackup implements Exception {
  const InvalidBackup(this.message);
  final String message;
}

class BackupSnapshot {
  BackupSnapshot._(
    this.createdAt,
    this.employees,
    this.events,
    this.reviews,
    this.consentRecords,
  );
  static const maxBytes = 20 * 1024 * 1024;
  final DateTime createdAt;
  final List<Map<String, Object?>> employees;
  final List<Map<String, Object?>> events;
  final List<Map<String, Object?>> reviews;
  final List<Map<String, Object?>> consentRecords;

  factory BackupSnapshot.fromRows({
    required DateTime createdAt,
    required List<Map<String, Object?>> employees,
    required List<Map<String, Object?>> events,
    List<Map<String, Object?>> reviews = const [],
    List<Map<String, Object?>> consentRecords = const [],
  }) => BackupSnapshot.decode(
    utf8.encode(
      jsonEncode({
        'format': 'control-recursos-humanos',
        'version': 4,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'employees': employees,
        'attendance': events,
        'attendanceReviews': reviews,
        'consentRecords': consentRecords,
      }),
    ),
  );

  factory BackupSnapshot.decode(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const InvalidBackup(
        'El respaldo está vacío o supera el límite de 20 MB.',
      );
    }
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const InvalidBackup('El archivo no contiene un respaldo válido.');
    }
    if (raw is! Map<String, dynamic> ||
        raw['format'] != 'control-recursos-humanos' ||
        ![1, 2, 3, 4].contains(raw['version'])) {
      throw const InvalidBackup(
        'Este archivo no corresponde a una versión de respaldo compatible.',
      );
    }
    final date = raw['createdAt'];
    final createdAt = date is String ? DateTime.tryParse(date) : null;
    final employeeRows = raw['employees'];
    final eventRows = raw['attendance'];
    final reviewRows = raw['version'] == 1
        ? <Object?>[]
        : raw['attendanceReviews'];
    final consentRows = raw['version'] == 3 || raw['version'] == 4
        ? raw['consentRecords']
        : <Object?>[];
    if (createdAt == null ||
        !createdAt.isUtc ||
        employeeRows is! List ||
        eventRows is! List ||
        reviewRows is! List ||
        consentRows is! List) {
      throw const InvalidBackup('El respaldo está incompleto.');
    }
    final employees = <Map<String, Object?>>[];
    final events = <Map<String, Object?>>[];
    final reviews = <Map<String, Object?>>[];
    final consents = <Map<String, Object?>>[];
    final employeeIds = <int>{};
    final numbers = <String>{};
    final eventIds = <int>{};
    final reviewIds = <int>{};
    final reviewedEvents = <int>{};
    final consentIds = <int>{};
    for (final row in employeeRows) {
      if (row is! Map<String, dynamic>) {
        throw const InvalidBackup('El respaldo contiene un empleado inválido.');
      }
      final id = row['id'];
      final number = row['number'];
      final name = row['name'];
      if (!_validId(id) ||
          !_validText(number, 30) ||
          !_validText(name, 120) ||
          !employeeIds.add(id as int) ||
          !numbers.add(number as String)) {
        throw const InvalidBackup(
          'El respaldo contiene empleados inválidos o repetidos.',
        );
      }
      employees.add(
        Map<String, Object?>.unmodifiable({
          'id': id,
          'number': number,
          'name': name,
        }),
      );
    }
    for (final row in eventRows) {
      if (row is! Map<String, dynamic>) {
        throw const InvalidBackup(
          'El respaldo contiene un movimiento inválido.',
        );
      }
      final id = row['id'];
      final number = row['employee_number'];
      final kind = row['kind'];
      final time = row['occurred_at'];
      final method = raw['version'] == 4
          ? row['capture_method'] ?? 'manual'
          : 'manual';
      final similarity = row['similarity'];
      final model = row['identity_model'];
      final liveness = row['liveness_method'];
      if (method != 'manual' && method != 'facial' ||
          method == 'facial' &&
              (similarity is! num ||
                  !similarity.isFinite ||
                  similarity < -1 ||
                  similarity > 1 ||
                  !_validText(model, 100) ||
                  liveness != 'blink_challenge_v1')) {
        throw const InvalidBackup(
          'El respaldo contiene información facial inválida.',
        );
      }
      if (!_validId(id) ||
          !eventIds.add(id as int) ||
          number is! String ||
          !numbers.contains(number) ||
          (kind != 'entry' && kind != 'exit') ||
          time is! int ||
          time < 0 ||
          time > 8640000000000000) {
        throw const InvalidBackup(
          'Hay movimientos inválidos o asociados a empleados inexistentes.',
        );
      }
      events.add(
        Map<String, Object?>.unmodifiable({
          'id': id,
          'employee_number': number,
          'kind': kind,
          'occurred_at': time,
          'capture_method': method,
          'similarity': method == 'facial' ? similarity : null,
          'identity_model': method == 'facial' ? model : null,
          'liveness_method': method == 'facial' ? liveness : null,
        }),
      );
    }
    for (final row in reviewRows) {
      if (row is! Map<String, dynamic>) {
        throw const InvalidBackup(
          'El respaldo contiene una revisión inválida.',
        );
      }
      final id = row['id'];
      final eventId = row['event_id'];
      final decision = row['decision'];
      final reviewer = row['reviewer'];
      final reason = row['reason'];
      final reviewedAt = row['reviewed_at'];
      if (!_validId(id) ||
          !reviewIds.add(id as int) ||
          !_validId(eventId) ||
          !eventIds.contains(eventId) ||
          !reviewedEvents.add(eventId as int) ||
          (decision != 'approved' && decision != 'rejected') ||
          !_validText(reviewer, 100) ||
          (reviewer as String).trim().length < 3 ||
          !_validText(reason, 500) ||
          (reason as String).trim().length < 10 ||
          reviewedAt is! int ||
          reviewedAt < 0 ||
          reviewedAt > 8640000000000000) {
        throw const InvalidBackup(
          'El respaldo contiene una revisión inválida.',
        );
      }
      reviews.add(
        Map<String, Object?>.unmodifiable({
          'id': id,
          'event_id': eventId,
          'decision': decision,
          'reviewer': reviewer,
          'reason': reason,
          'reviewed_at': reviewedAt,
        }),
      );
    }
    for (final row in consentRows) {
      if (row is! Map<String, dynamic>) {
        throw const InvalidBackup(
          'El respaldo contiene un consentimiento inválido.',
        );
      }
      final id = row['id'];
      final number = row['employee_number'];
      final kind = row['kind'];
      final reference = row['document_reference'];
      final actor = row['actor'];
      final time = row['occurred_at'];
      if (!_validId(id) ||
          !consentIds.add(id as int) ||
          number is! String ||
          !numbers.contains(number) ||
          (kind != 'recorded' && kind != 'revoked') ||
          !_validText(reference, 120) ||
          (reference as String).trim().length < 5 ||
          !_validText(actor, 100) ||
          (actor as String).trim().length < 3 ||
          time is! int ||
          time < 0 ||
          time > 8640000000000000) {
        throw const InvalidBackup(
          'El respaldo contiene un consentimiento inválido.',
        );
      }
      consents.add(
        Map<String, Object?>.unmodifiable({
          'id': id,
          'employee_number': number,
          'kind': kind,
          'document_reference': reference,
          'actor': actor,
          'occurred_at': time,
        }),
      );
    }
    employees.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
    events.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
    reviews.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
    consents.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
    final activeConsents = <String, bool>{};
    for (final row in consents) {
      final number = row['employee_number'] as String;
      final wasActive = activeConsents[number] ?? false;
      final isRecord = row['kind'] == 'recorded';
      if (isRecord == wasActive) {
        throw const InvalidBackup(
          'El respaldo contiene una secuencia de consentimientos inválida.',
        );
      }
      activeConsents[number] = isRecord;
    }
    return BackupSnapshot._(
      createdAt,
      List.unmodifiable(employees),
      List.unmodifiable(events),
      List.unmodifiable(reviews),
      List.unmodifiable(consents),
    );
  }

  static bool _validId(Object? value) =>
      value is int && value > 0 && value < 9223372036854775807;
  static bool _validText(Object? value, int max) =>
      value is String &&
      value.trim().isNotEmpty &&
      value.length <= max &&
      !value.contains('\u0000');

  Uint8List encode() {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'control-recursos-humanos',
          'version': 4,
          'createdAt': createdAt.toUtc().toIso8601String(),
          'employees': employees,
          'attendance': events,
          'attendanceReviews': reviews,
          'consentRecords': consentRecords,
        }),
      ),
    );
    if (bytes.length > maxBytes) {
      throw const InvalidBackup('El respaldo supera el límite de 20 MB.');
    }
    return bytes;
  }
}
