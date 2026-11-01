import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/audit/audit_store.dart';
import 'package:kiosk/backup/backup_service.dart';
import 'package:kiosk/database/local_database.dart';
import 'package:kiosk/employees/employee_store.dart';
import 'package:kiosk/vision/consent_store.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Directory temp;
  late LocalDatabase database;
  late ConsentStore consents;
  var allowed = true;
  final now = DateTime(2026, 10, 30, 12);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('rh_consents_');
    database = LocalDatabase(
      filePath: path.join(temp.path, 'test.db'),
      factory: databaseFactoryFfi,
    );
    allowed = true;
    consents = ConsentStore(
      database,
      authorize: () {
        if (!allowed) throw StateError('Sin permiso');
      },
      actor: () => 'administrador',
      clock: () => now,
    );
    await EmployeeStore(
      database: database,
      authorize: () {},
    ).add('001', 'Ana Pérez');
  });

  tearDown(() async {
    await database.close();
    await temp.delete(recursive: true);
  });

  test(
    'Registra y revoca sin perder el historial ni permitir duplicados',
    () async {
      expect((await consents.list()).single.kind, isNull);
      await consents.record('001', ConsentKind.recorded, 'CONS-2026-001');
      expect((await consents.list()).single.active, isTrue);
      await expectLater(
        consents.record('001', ConsentKind.recorded, 'CONS-2026-002'),
        throwsA(isA<ConsentRuleError>()),
      );
      await consents.record('001', ConsentKind.revoked, 'REV-2026-001');
      expect((await consents.list()).single.active, isFalse);
      await expectLater(
        consents.record('001', ConsentKind.revoked, 'REV-2026-002'),
        throwsA(isA<ConsentRuleError>()),
      );

      final rows = await (await database.open()).query(
        'consent_records',
        orderBy: 'id',
      );
      expect(rows.map((row) => row['kind']), ['recorded', 'revoked']);
      final actions = (await AuditStore(
        database,
        authorize: () {},
      ).list()).map((entry) => entry.action);
      expect(
        actions,
        containsAll([AuditAction.consentRecorded, AuditAction.consentRevoked]),
      );
    },
  );

  test('Exige permiso, empleado existente y folio válido', () async {
    await expectLater(
      consents.record('001', ConsentKind.recorded, '123'),
      throwsA(isA<ConsentRuleError>()),
    );
    await expectLater(
      consents.record('999', ConsentKind.recorded, 'CONS-2026-999'),
      throwsA(isA<ConsentRuleError>()),
    );
    allowed = false;
    await expectLater(consents.list(), throwsStateError);
    await expectLater(
      consents.record('001', ConsentKind.recorded, 'CONS-2026-001'),
      throwsStateError,
    );
    allowed = true;
    expect((await consents.list()).single.kind, isNull);
  });

  test('El respaldo restaura el folio y la revocación', () async {
    await consents.record('001', ConsentKind.recorded, 'CONS-2026-001');
    await consents.record('001', ConsentKind.revoked, 'REV-2026-001');
    final backup = BackupService(database, authorize: () {});
    final snapshot = await backup.capture();
    expect(snapshot.consentRecords, hasLength(2));
    await backup.restore(snapshot);
    await database.close();
    expect((await consents.list()).single.kind, ConsentKind.revoked);
  });

  test('La actualización desde la base anterior conserva empleados', () async {
    final legacyPath = path.join(temp.path, 'legacy-v8.db');
    final legacy = await databaseFactoryFfi.openDatabase(
      legacyPath,
      options: OpenDatabaseOptions(
        version: 8,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE employees (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              number TEXT NOT NULL UNIQUE,
              name TEXT NOT NULL
            )
          ''');
          await db.insert('employees', {'number': '002', 'name': 'Luis López'});
        },
      ),
    );
    await legacy.close();
    final upgraded = LocalDatabase(
      filePath: legacyPath,
      factory: databaseFactoryFfi,
    );
    addTearDown(upgraded.close);
    final store = ConsentStore(
      upgraded,
      authorize: () {},
      actor: () => 'administrador',
    );

    final employeesAfterUpgrade = await store.list();
    expect(employeesAfterUpgrade.single.employeeName, 'Luis López');
    expect(employeesAfterUpgrade.single.kind, isNull);
  });
}
