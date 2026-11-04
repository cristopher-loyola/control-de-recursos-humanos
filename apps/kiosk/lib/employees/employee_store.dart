import 'package:sqflite/sqflite.dart';

import '../database/local_database.dart';
import 'employee_validation.dart';
import '../audit/audit_store.dart';

class Employee {
  const Employee({
    required this.number,
    required this.name,
    this.hasFace = false,
  });
  final String number;
  final String name;
  final bool hasFace;
}

class DuplicateEmployee implements Exception {}

class EmployeeStore {
  EmployeeStore({
    String databaseName = 'kiosk.db',
    LocalDatabase? database,
    required this.authorize,
    this.actor,
  }) : _database = database ?? LocalDatabase(name: databaseName);
  final LocalDatabase _database;
  final void Function() authorize;
  final String Function()? actor;

  Future<List<Employee>> list() async {
    final rows = await (await _database.open()).rawQuery('''
      SELECT e.*, EXISTS(SELECT 1 FROM face_templates t WHERE t.employee_number = e.number) AS has_face
      FROM employees e ORDER BY e.name COLLATE NOCASE, e.number
    ''');
    return rows
        .map(
          (row) => Employee(
            number: row['number'] as String,
            name: row['name'] as String,
            hasFace: row['has_face'] == 1,
          ),
        )
        .toList();
  }

  Future<void> add(String number, String name) async {
    authorize();
    final normalizedNumber = number.trim();
    final normalizedName = name.trim();
    final validationError =
        validateEmployeeNumber(normalizedNumber) ??
        validateEmployeeName(normalizedName);
    if (validationError != null) {
      throw ArgumentError(validationError);
    }
    try {
      final db = await _database.open();
      await db.transaction((txn) async {
        authorize();
        await writeAudit(
          txn,
          action: AuditAction.employeeCreated,
          actor: actor?.call() ?? 'Administrador',
          details: {'employeeNumber': normalizedNumber},
        );
        await txn.insert('employees', {
          'number': normalizedNumber,
          'name': normalizedName,
        }, conflictAlgorithm: ConflictAlgorithm.abort);
      });
    } on DatabaseException catch (error) {
      if (error.isUniqueConstraintError()) {
        throw DuplicateEmployee();
      }
      rethrow;
    }
  }

  Future<void> close() => _database.close();
}
