import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/database/local_database.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'La actualización conserva empleados y agrega organización y cuentas de RH',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'kiosk-roles-migration-',
      );
      final filePath = path.join(directory.path, 'kiosk.db');
      final old = await databaseFactoryFfi.openDatabase(
        filePath,
        options: OpenDatabaseOptions(
          version: 5,
          onCreate: (db, version) async {
            await db.execute(
              'CREATE TABLE attendance_events (id INTEGER PRIMARY KEY, employee_number TEXT, kind TEXT, occurred_at INTEGER)',
            );
            await db.execute(
              'CREATE TABLE employees (id INTEGER PRIMARY KEY, number TEXT NOT NULL, name TEXT NOT NULL)',
            );
          },
        ),
      );
      await old.insert('employees', {
        'number': '101',
        'name': 'Empleado existente',
      });
      await old.close();

      final migrated = LocalDatabase(
        filePath: filePath,
        factory: databaseFactoryFfi,
      );
      try {
        final db = await migrated.open();
        expect((await db.query('employees')).single['number'], '101');
        expect(await db.query('organization'), isEmpty);
        expect(await db.query('rh_accounts'), isEmpty);
      } finally {
        await migrated.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
