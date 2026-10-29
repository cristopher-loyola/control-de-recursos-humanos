import 'dart:convert';
import 'dart:typed_data';

class InvalidBackup implements Exception {
  const InvalidBackup(this.message);
  final String message;
}

class BackupSnapshot {
  BackupSnapshot._(this.createdAt, this.employees, this.events);
  static const maxBytes = 20 * 1024 * 1024;
  final DateTime createdAt;
  final List<Map<String, Object?>> employees;
  final List<Map<String, Object?>> events;

  factory BackupSnapshot.fromRows({
    required DateTime createdAt,
    required List<Map<String, Object?>> employees,
    required List<Map<String, Object?>> events,
  }) => BackupSnapshot.decode(
    utf8.encode(
      jsonEncode({
        'format': 'control-recursos-humanos',
        'version': 1,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'employees': employees,
        'attendance': events,
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
        raw['version'] != 1) {
      throw const InvalidBackup(
        'Este archivo no corresponde a una versión de respaldo compatible.',
      );
    }
    final date = raw['createdAt'];
    final createdAt = date is String ? DateTime.tryParse(date) : null;
    final employeeRows = raw['employees'];
    final eventRows = raw['attendance'];
    if (createdAt == null ||
        !createdAt.isUtc ||
        employeeRows is! List ||
        eventRows is! List) {
      throw const InvalidBackup('El respaldo está incompleto.');
    }
    final employees = <Map<String, Object?>>[];
    final events = <Map<String, Object?>>[];
    final employeeIds = <int>{};
    final numbers = <String>{};
    final eventIds = <int>{};
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
        }),
      );
    }
    employees.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
    events.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
    return BackupSnapshot._(
      createdAt,
      List.unmodifiable(employees),
      List.unmodifiable(events),
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
          'version': 1,
          'createdAt': createdAt.toUtc().toIso8601String(),
          'employees': employees,
          'attendance': events,
        }),
      ),
    );
    if (bytes.length > maxBytes) {
      throw const InvalidBackup('El respaldo supera el límite de 20 MB.');
    }
    return bytes;
  }
}
