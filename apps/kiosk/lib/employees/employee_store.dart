import 'package:sqflite/sqflite.dart';

import '../database/local_database.dart';
import 'employee_validation.dart';
import '../audit/audit_store.dart';

class Employee {
  const Employee({
    required this.number,
    required this.name,
    this.hasFace = false,
    this.departmentId,
    this.departmentName,
    this.dailyWageCents,
    this.departmentWageCents,
  });
  final String number;
  final String name;
  final bool hasFace;
  final int? departmentId;
  final String? departmentName;

  /// Salario diario propio en centavos; null usa el del departamento.
  final int? dailyWageCents;
  final int? departmentWageCents;

  int? get effectiveWageCents => dailyWageCents ?? departmentWageCents;
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
      SELECT e.*, d.name AS department_name, d.daily_wage_cents AS department_wage_cents,
             EXISTS(SELECT 1 FROM face_templates t WHERE t.employee_number = e.number) AS has_face
      FROM employees e LEFT JOIN departments d ON d.id = e.department_id
      ORDER BY e.name COLLATE NOCASE, e.number
    ''');
    return rows
        .map(
          (row) => Employee(
            number: row['number'] as String,
            name: row['name'] as String,
            hasFace: row['has_face'] == 1,
            departmentId: row['department_id'] as int?,
            departmentName: row['department_name'] as String?,
            dailyWageCents: row['daily_wage_cents'] as int?,
            departmentWageCents: row['department_wage_cents'] as int?,
          ),
        )
        .toList();
  }

  Future<void> add(String number, String name, {int? departmentId}) async {
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
          'department_id': departmentId,
          'registered_at': DateTime.now().toUtc().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.abort);
      });
    } on DatabaseException catch (error) {
      if (error.isUniqueConstraintError()) {
        throw DuplicateEmployee();
      }
      rethrow;
    }
  }

  /// Da de alta con el siguiente número consecutivo y lo devuelve. Se calcula
  /// dentro de la transacción para que dos altas seguidas no repitan número.
  Future<String> register(String name, {int? departmentId}) async {
    authorize();
    final normalizedName = name.trim();
    final validationError = validateEmployeeName(normalizedName);
    if (validationError != null) {
      throw ArgumentError(validationError);
    }
    final db = await _database.open();
    return db.transaction((txn) async {
      authorize();
      final rows = await txn.rawQuery(
        'SELECT COALESCE(MAX(CAST(number AS INTEGER)), 0) + 1 AS next FROM employees',
      );
      final number = (rows.single['next'] as int).toString();
      await txn.insert('employees', {
        'number': number,
        'name': normalizedName,
        'department_id': departmentId,
        'registered_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.abort);
      await writeAudit(
        txn,
        action: AuditAction.employeeCreated,
        actor: actor?.call() ?? 'Administrador',
        details: {'employeeNumber': number},
      );
      return number;
    });
  }

  /// Cambia el departamento y con él el horario contra el que se revisan sus checadas.
  Future<void> setDepartment(String number, int departmentId) async {
    authorize();
    final db = await _database.open();
    await db.transaction((txn) async {
      authorize();
      final rows = await txn.rawQuery(
        '''
        SELECT d.name AS before,
               (SELECT name FROM departments WHERE id = ?) AS after
        FROM employees e LEFT JOIN departments d ON d.id = e.department_id
        WHERE e.number = ?
        ''',
        [departmentId, number],
      );
      if (rows.isEmpty) throw ArgumentError('El empleado ya no existe.');
      if (rows.single['after'] == null) {
        throw ArgumentError('El departamento ya no existe.');
      }
      await txn.update(
        'employees',
        {'department_id': departmentId},
        where: 'number = ?',
        whereArgs: [number],
      );
      await writeAudit(
        txn,
        action: AuditAction.employeeDepartmentChanged,
        actor: actor?.call() ?? 'Administrador',
        details: {
          'employeeNumber': number,
          'before': rows.single['before'],
          'after': rows.single['after'],
        },
      );
    });
  }

  /// Salario diario propio en centavos; null vuelve al del departamento.
  Future<void> setDailyWage(String number, int? cents) async {
    authorize();
    if (cents != null && (cents < 0 || cents > 100000000)) {
      throw ArgumentError(
        'El salario diario debe estar entre \$0 y \$1,000,000.',
      );
    }
    final db = await _database.open();
    await db.transaction((txn) async {
      authorize();
      final changed = await txn.update(
        'employees',
        {'daily_wage_cents': cents},
        where: 'number = ?',
        whereArgs: [number],
      );
      if (changed == 0) throw ArgumentError('El empleado ya no existe.');
      await writeAudit(
        txn,
        action: AuditAction.employeeWageChanged,
        actor: actor?.call() ?? 'Administrador',
        details: {'employeeNumber': number, 'dailyWage': cents},
      );
    });
  }

  Future<void> close() => _database.close();
}
