import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/attendance/attendance_store.dart';
import 'package:kiosk/backup/backup_service.dart';
import 'package:kiosk/backup/backup_snapshot.dart';
import 'package:kiosk/database/local_database.dart';
import 'package:kiosk/employees/employee_store.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Directory temp;
  late LocalDatabase database;
  late EmployeeStore employees;
  late AttendanceStore attendance;
  late BackupService backups;
  late DateTime now;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('rh_database_test_');
    database = LocalDatabase(
      filePath: path.join(temp.path, 'test.db'),
      factory: databaseFactoryFfi,
    );
    employees = EmployeeStore(database: database, authorize: () {});
    now = DateTime(2026, 10, 28, 8);
    attendance = AttendanceStore(
      database,
      authorizeRecord: () {},
      clock: () => now,
    );
    backups = BackupService(database, authorize: () {});
  });

  tearDown(() async {
    await database.close();
    await temp.delete(recursive: true);
  });

  test(
    'La migración conserva empleados y el historial permanece al reabrir',
    () async {
      final legacy = await databaseFactoryFfi.openDatabase(
        database.filePath!,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            await db.execute('''
          CREATE TABLE employees (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            number TEXT NOT NULL UNIQUE CHECK(length(trim(number)) BETWEEN 1 AND 30),
            name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 120)
          )
        ''');
            await db.insert('employees', {
              'number': '001',
              'name': 'Ana Pérez',
            });
          },
        ),
      );
      await legacy.close();
      expect((await employees.list()).single.name, 'Ana Pérez');
      await attendance.record('001', AttendanceKind.entry);
      await database.close();
      expect((await employees.list()).single.number, '001');
      expect((await attendance.lastFor('001'))!.kind, AttendanceKind.entry);
    },
  );

  test(
    'Limita un par diario y evita entradas concurrentes duplicadas',
    () async {
      await employees.add('001', 'Ana Pérez');
      await expectLater(
        attendance.record('001', AttendanceKind.exit),
        throwsA(isA<AttendanceRuleError>()),
      );
      Future<bool> attempt() async {
        try {
          await attendance.record('001', AttendanceKind.entry);
          return true;
        } on AttendanceRuleError {
          return false;
        }
      }

      final results = await Future.wait([attempt(), attempt()]);
      expect(results.where((value) => value), hasLength(1));
      now = now.add(const Duration(hours: 8));
      await attendance.record('001', AttendanceKind.exit);
      await expectLater(
        attendance.record('001', AttendanceKind.entry),
        throwsA(isA<AttendanceRuleError>()),
      );
      await expectLater(
        attendance.record('001', AttendanceKind.exit),
        throwsA(isA<AttendanceRuleError>()),
      );
      expect(await attendance.forDay(now), hasLength(2));

      await employees.add('002', 'José Muñoz');
      await attendance.record('002', AttendanceKind.entry);
      now = DateTime(2026, 10, 29, 8);
      await attendance.record('001', AttendanceKind.entry);
      now = now.add(const Duration(hours: 8));
      await attendance.record('001', AttendanceKind.exit);
      expect(await attendance.forDay(now), hasLength(2));
    },
  );

  test(
    'Permite salida al día siguiente y filtra correctamente la medianoche',
    () async {
      await employees.add('001', 'Ana Pérez');
      now = DateTime(2026, 10, 28, 23, 59);
      await attendance.record('001', AttendanceKind.entry);
      now = DateTime(2026, 10, 29);
      await attendance.record('001', AttendanceKind.exit);
      expect(
        (await attendance.forDay(DateTime(2026, 10, 28))).single.kind,
        AttendanceKind.entry,
      );
      expect((await attendance.forDay(now)).single.kind, AttendanceKind.exit);
    },
  );

  test('Rechaza empleados inexistentes y retrocesos del reloj', () async {
    await expectLater(
      attendance.record('999', AttendanceKind.entry),
      throwsA(isA<AttendanceRuleError>()),
    );
    await employees.add('001', 'Ana Pérez');
    await attendance.record('001', AttendanceKind.entry);
    now = now.subtract(const Duration(hours: 1));
    await expectLater(
      attendance.record('001', AttendanceKind.exit),
      throwsA(isA<AttendanceRuleError>()),
    );
  });

  test('La checada manual exige una sesión de personal autorizado', () async {
    await employees.add('001', 'Ana Pérez');
    var allowed = false;
    final protectedAttendance = AttendanceStore(
      database,
      authorizeRecord: () {
        if (!allowed) throw StateError('Sin acceso de RH');
      },
      clock: () => now,
    );
    await expectLater(
      protectedAttendance.record('001', AttendanceKind.entry),
      throwsStateError,
    );
    expect(await attendance.forDay(now), isEmpty);
    allowed = true;
    await protectedAttendance.record('001', AttendanceKind.entry);
    expect(await attendance.forDay(now), hasLength(1));
  });

  test(
    'El respaldo restaura empleados e historial y conserva las reglas diarias',
    () async {
      await employees.add('001', 'Ana Pérez');
      await attendance.record('001', AttendanceKind.entry);
      now = now.add(const Duration(hours: 8));
      await attendance.record('001', AttendanceKind.exit);
      final exported = (await backups.capture()).encode();
      await employees.add('002', 'José Muñoz');
      await attendance.record('002', AttendanceKind.entry);

      await backups.restore(BackupSnapshot.decode(exported));
      await database.close();
      expect((await employees.list()).single.number, '001');
      expect(await attendance.forDay(now), hasLength(2));
      await expectLater(
        attendance.record('001', AttendanceKind.entry),
        throwsA(isA<AttendanceRuleError>()),
      );
      final restored = await backups.capture();
      final original = BackupSnapshot.decode(exported);
      expect(restored.employees, original.employees);
      expect(restored.events, original.events);
    },
  );

  test('Una restauración fallida revierte también los borrados', () async {
    await employees.add('002', 'José Muñoz');
    await attendance.record('002', AttendanceKind.entry);
    final before = await backups.capture();
    final incoming = BackupSnapshot.fromRows(
      createdAt: now,
      employees: [
        {'id': 1, 'number': '001', 'name': 'Ana Pérez'},
      ],
      events: [],
    );
    final db = await database.open();
    await db.execute('''
      CREATE TRIGGER simulate_restore_failure BEFORE INSERT ON employees
      WHEN NEW.number = '001'
      BEGIN SELECT RAISE(ABORT, 'simulated failure'); END
    ''');
    await expectLater(
      backups.restore(incoming),
      throwsA(isA<DatabaseException>()),
    );
    final after = await backups.capture();
    expect(after.employees, before.employees);
    expect(after.events, before.events);
  });
}
