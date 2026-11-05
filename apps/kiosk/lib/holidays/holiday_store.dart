import 'package:sqflite/sqflite.dart';

import '../audit/audit_store.dart';
import '../database/local_database.dart';

class Holiday {
  const Holiday({
    required this.id,
    required this.day,
    required this.name,
    this.departmentId,
    this.departmentName,
  });
  final int id;
  final DateTime day;
  final String name;
  final int? departmentId;
  final String? departmentName;

  factory Holiday.fromRow(Map<String, Object?> row) => Holiday(
    id: row['id'] as int,
    day: parseDay(row['day'] as String),
    name: row['name'] as String,
    departmentId: row['department_id'] as int?,
    departmentName: row['department_name'] as String?,
  );
}

class HolidayRuleError implements Exception {
  const HolidayRuleError(this.message);
  final String message;
}

String formatDay(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

DateTime parseDay(String value) {
  final parts = value.split('-').map(int.parse).toList();
  return DateTime(parts[0], parts[1], parts[2]);
}

DateTime _nthMonday(int year, int month, int n) {
  final first = DateTime(year, month);
  final offset = (DateTime.monday - first.weekday + 7) % 7;
  return DateTime(year, month, 1 + offset + 7 * (n - 1));
}

/// Descansos obligatorios de la Ley Federal del Trabajo (art. 74).
/// No incluye jornadas electorales: se agregan a mano cuando se publican.
List<({DateTime day, String name})> officialHolidays(int year) => [
  (day: DateTime(year, 1, 1), name: 'Año Nuevo'),
  (day: _nthMonday(year, 2, 1), name: 'Día de la Constitución'),
  (day: _nthMonday(year, 3, 3), name: 'Natalicio de Benito Juárez'),
  (day: DateTime(year, 5, 1), name: 'Día del Trabajo'),
  (day: DateTime(year, 9, 16), name: 'Día de la Independencia'),
  if ((year - 2024) % 6 == 0)
    (day: DateTime(year, 10, 1), name: 'Transmisión del Poder Ejecutivo'),
  (day: _nthMonday(year, 11, 3), name: 'Día de la Revolución'),
  (day: DateTime(year, 12, 25), name: 'Navidad'),
];

class HolidayStore {
  HolidayStore(this.database, {required this.authorize, this.actor});
  final LocalDatabase database;
  final void Function() authorize;
  final String Function()? actor;

  Future<List<Holiday>> list({DateTime? from, DateTime? to}) async {
    final db = await database.open();
    final rows = await db.rawQuery(
      '''
      SELECT h.*, d.name AS department_name
      FROM holidays h LEFT JOIN departments d ON d.id = h.department_id
      WHERE (? IS NULL OR h.day >= ?) AND (? IS NULL OR h.day < ?)
      ORDER BY h.day, d.name
      ''',
      [
        from == null ? null : formatDay(from),
        from == null ? null : formatDay(from),
        to == null ? null : formatDay(to),
        to == null ? null : formatDay(to),
      ],
    );
    return rows.map(Holiday.fromRow).toList();
  }

  Future<void> add({
    required DateTime day,
    required String name,
    int? departmentId,
  }) async {
    authorize();
    final normalized = name.trim();
    if (normalized.length < 2 || normalized.length > 80) {
      throw const HolidayRuleError('Escribe un nombre de 2 a 80 caracteres.');
    }
    final db = await database.open();
    try {
      await db.transaction((txn) async {
        authorize();
        await _insert(txn, day, normalized, departmentId);
      });
    } on DatabaseException catch (error) {
      if (error.isUniqueConstraintError()) {
        throw const HolidayRuleError(
          'Ese día ya está registrado para ese alcance.',
        );
      }
      rethrow;
    }
  }

  /// Agrega los festivos oficiales del año que falten; devuelve cuántos agregó.
  Future<int> addOfficial(int year) async {
    authorize();
    final db = await database.open();
    return db.transaction((txn) async {
      authorize();
      var added = 0;
      for (final holiday in officialHolidays(year)) {
        final existing = await txn.query(
          'holidays',
          columns: ['id'],
          where: 'day = ? AND department_id IS NULL',
          whereArgs: [formatDay(holiday.day)],
          limit: 1,
        );
        if (existing.isNotEmpty) continue;
        await _insert(txn, holiday.day, holiday.name, null);
        added++;
      }
      return added;
    });
  }

  Future<void> remove(int id) async {
    authorize();
    final db = await database.open();
    await db.transaction((txn) async {
      authorize();
      final rows = await txn.rawQuery(
        '''
        SELECT h.day, h.name, d.name AS scope FROM holidays h
        LEFT JOIN departments d ON d.id = h.department_id WHERE h.id = ?
        ''',
        [id],
      );
      if (rows.isEmpty) return;
      await txn.delete('holidays', where: 'id = ?', whereArgs: [id]);
      await writeAudit(
        txn,
        action: AuditAction.holidayRemoved,
        actor: actor?.call(),
        details: {
          'day': rows.single['day'],
          'name': rows.single['name'],
          'scope': rows.single['scope'],
        },
      );
    });
  }

  Future<void> _insert(
    Transaction txn,
    DateTime day,
    String name,
    int? departmentId,
  ) async {
    String? scope;
    if (departmentId != null) {
      final department = await txn.query(
        'departments',
        columns: ['name'],
        where: 'id = ?',
        whereArgs: [departmentId],
      );
      if (department.isEmpty) {
        throw const HolidayRuleError('El departamento ya no existe.');
      }
      scope = department.single['name'] as String;
    }
    await txn.insert('holidays', {
      'day': formatDay(day),
      'name': name,
      'department_id': departmentId,
    }, conflictAlgorithm: ConflictAlgorithm.abort);
    await writeAudit(
      txn,
      action: AuditAction.holidayAdded,
      actor: actor?.call(),
      details: {'day': formatDay(day), 'name': name, 'scope': scope},
    );
  }
}
