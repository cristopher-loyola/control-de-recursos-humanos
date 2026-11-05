import 'package:sqflite/sqflite.dart';

import '../audit/audit_store.dart';
import '../database/local_database.dart';
import 'schedule.dart';

class Department {
  const Department({
    required this.id,
    required this.name,
    required this.entryMinutes,
    required this.exitMinutes,
    required this.toleranceMinutes,
    this.workDays = WorkDays.mondayToFriday,
    this.employeeCount = 0,
  });
  final int id;
  final String name;
  final int entryMinutes;
  final int exitMinutes;
  final int toleranceMinutes;

  /// Días laborables como bits: lunes = 1 … domingo = 64.
  final int workDays;
  final int employeeCount;

  DepartmentSchedule get schedule => DepartmentSchedule(
    departmentName: name,
    entryMinutes: entryMinutes,
    exitMinutes: exitMinutes,
    toleranceMinutes: toleranceMinutes,
  );

  factory Department.fromRow(Map<String, Object?> row) => Department(
    id: row['id'] as int,
    name: row['name'] as String,
    entryMinutes: row['entry_minutes'] as int,
    exitMinutes: row['exit_minutes'] as int,
    toleranceMinutes: row['tolerance_minutes'] as int,
    workDays: (row['work_days'] as int?) ?? WorkDays.mondayToFriday,
    employeeCount: (row['employee_count'] as int?) ?? 0,
  );
}

class DepartmentRuleError implements Exception {
  const DepartmentRuleError(this.message);
  final String message;
}

class DepartmentStore {
  DepartmentStore(this.database, {required this.authorize, this.actor});
  final LocalDatabase database;
  final void Function() authorize;
  final String Function()? actor;

  Future<List<Department>> list() async {
    final rows = await (await database.open()).rawQuery('''
      SELECT d.*, (SELECT count(*) FROM employees e WHERE e.department_id = d.id) AS employee_count
      FROM departments d ORDER BY d.name COLLATE NOCASE
    ''');
    return rows.map(Department.fromRow).toList();
  }

  /// Crea el departamento, o cambia su nombre y horario si se indica [id].
  Future<void> save({
    int? id,
    required String name,
    required int entryMinutes,
    required int exitMinutes,
    required int toleranceMinutes,
    int workDays = WorkDays.mondayToFriday,
  }) async {
    authorize();
    final normalized = name.trim();
    if (normalized.length < 2 || normalized.length > 80) {
      throw const DepartmentRuleError(
        'Escribe un nombre de 2 a 80 caracteres.',
      );
    }
    if (entryMinutes == exitMinutes) {
      throw const DepartmentRuleError(
        'La hora de salida debe ser distinta a la de entrada.',
      );
    }
    if (toleranceMinutes < 0 || toleranceMinutes > 240) {
      throw const DepartmentRuleError(
        'La tolerancia debe estar entre 0 y 240 minutos.',
      );
    }
    if (workDays < 1 || workDays > 127) {
      throw const DepartmentRuleError('Elige al menos un día laborable.');
    }
    final values = {
      'work_days': workDays,
      'name': normalized,
      'entry_minutes': entryMinutes,
      'exit_minutes': exitMinutes,
      'tolerance_minutes': toleranceMinutes,
    };
    try {
      final db = await database.open();
      await db.transaction((txn) async {
        authorize();
        if (id == null) {
          await txn.insert('departments', values);
        } else {
          final changed = await txn.update(
            'departments',
            values,
            where: 'id = ?',
            whereArgs: [id],
          );
          if (changed == 0) {
            throw const DepartmentRuleError('El departamento ya no existe.');
          }
        }
        await writeAudit(
          txn,
          action: id == null
              ? AuditAction.departmentCreated
              : AuditAction.departmentUpdated,
          actor: actor?.call(),
          details: {
            'name': normalized,
            'entry': formatMinutes(entryMinutes),
            'exit': formatMinutes(exitMinutes),
            'tolerance': toleranceMinutes,
            'days': WorkDays.describe(workDays),
          },
        );
      });
    } on DatabaseException catch (error) {
      if (error.isUniqueConstraintError()) {
        throw const DepartmentRuleError(
          'Ya existe un departamento con ese nombre.',
        );
      }
      rethrow;
    }
  }
}
