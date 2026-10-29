import 'package:sqflite/sqflite.dart';

import '../database/local_database.dart';
import 'employee_validation.dart';

class Employee {
  const Employee({required this.number, required this.name});
  final String number;
  final String name;
}

class DuplicateEmployee implements Exception {}

class EmployeeStore {
  EmployeeStore({String databaseName = 'kiosk.db', LocalDatabase? database})
    : _database = database ?? LocalDatabase(name: databaseName);
  final LocalDatabase _database;

  Future<List<Employee>> list() async {
    final rows = await (await _database.open()).query(
      'employees',
      orderBy: 'name COLLATE NOCASE, number',
    );
    return rows
        .map(
          (row) => Employee(
            number: row['number'] as String,
            name: row['name'] as String,
          ),
        )
        .toList();
  }

  Future<void> add(String number, String name) async {
    final normalizedNumber = number.trim();
    final normalizedName = name.trim();
    final validationError =
        validateEmployeeNumber(normalizedNumber) ??
        validateEmployeeName(normalizedName);
    if (validationError != null) {
      throw ArgumentError(validationError);
    }
    try {
      await (await _database.open()).insert('employees', {
        'number': normalizedNumber,
        'name': normalizedName,
      }, conflictAlgorithm: ConflictAlgorithm.abort);
    } on DatabaseException catch (error) {
      if (error.isUniqueConstraintError()) {
        throw DuplicateEmployee();
      }
      rethrow;
    }
  }

  Future<void> close() => _database.close();
}
