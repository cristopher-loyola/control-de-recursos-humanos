import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/audit/audit_store.dart';
import 'package:kiosk/auth/admin_auth.dart';
import 'package:kiosk/auth/password_hasher.dart';
import 'package:kiosk/backup/backup_service.dart';
import 'package:kiosk/database/local_database.dart';
import 'package:kiosk/employees/employee_store.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class AuditTestHasher extends PasswordHasher {
  @override
  Future<List<int>> derive(String password, List<int> salt) async =>
      List.generate(
        32,
        (index) =>
            (password.codeUnitAt(index % password.length) +
                salt[index % salt.length]) &
            255,
      );
}

void main() {
  sqfliteFfiInit();
  late Directory temp;
  late LocalDatabase database;
  late AdminAuth auth;
  late EmployeeStore employees;
  late BackupService backups;
  late AuditStore audit;
  const password = 'Una frase de prueba';

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('rh_audit_test_');
    database = LocalDatabase(
      filePath: path.join(temp.path, 'test.db'),
      factory: databaseFactoryFfi,
    );
    auth = AdminAuth(database, hasher: AuditTestHasher());
    await auth.initialize();
    await auth.create('admin', password);
    employees = EmployeeStore(
      database: database,
      authorize: auth.requireAdmin,
      actor: () => auth.administratorName,
    );
    backups = BackupService(
      database,
      authorize: auth.requireAdmin,
      actor: () => auth.administratorName,
    );
    audit = AuditStore(database, authorize: auth.requireAdmin);
  });

  tearDown(() async {
    auth.dispose();
    await database.close();
    await temp.delete(recursive: true);
  });

  test('Registra al actor y no registra altas rechazadas', () async {
    await employees.add('001', 'Ana Pérez');
    await expectLater(
      employees.add('001', 'Otra persona'),
      throwsA(isA<DuplicateEmployee>()),
    );
    final entries = await audit.list();
    expect(
      entries.where((entry) => entry.action == AuditAction.employeeCreated),
      hasLength(1),
    );
    expect(entries.first.actor, 'admin');
    expect(entries.first.details['employeeNumber'], '001');
    expect(entries.last.action, AuditAction.administratorCreated);
    await database.close();
    expect(await audit.list(), hasLength(2));
  });

  test(
    'Protege la consulta y registra accesos sin guardar credenciales',
    () async {
      auth.logout();
      await expectLater(audit.list(), throwsA(isA<AdminAccessRequired>()));
      await expectLater(
        auth.login('usuario-inexistente', 'clave-incorrecta'),
        throwsA(isA<AuthenticationError>()),
      );
      await auth.login('admin', password);
      final entries = await audit.list();
      expect(entries.first.action, AuditAction.loginSucceeded);
      expect(entries.first.actor, 'admin');
      final failure = entries.singleWhere(
        (entry) => entry.action == AuditAction.loginFailed,
      );
      expect(failure.actor, isNull);
      final rows = await (await database.open()).query('audit_entries');
      expect(rows.toString(), isNot(contains(password)));
      expect(rows.toString(), isNot(contains('clave-incorrecta')));
      expect(rows.toString(), isNot(contains('usuario-inexistente')));
    },
  );

  test('Registra exportación solo después de guardar y una sola vez', () async {
    final export = await backups.prepareExport();
    expect(
      (await audit.list()).where((e) => e.action == AuditAction.backupExported),
      isEmpty,
    );
    await export.confirmSaved();
    await export.confirmSaved();
    final entries = (await audit.list()).where(
      (e) => e.action == AuditAction.backupExported,
    );
    expect(entries, hasLength(1));
    expect(entries.single.actor, 'admin');
  });

  test('La restauración conserva el historial y añade una acción', () async {
    await employees.add('001', 'Ana Pérez');
    final snapshot = await backups.capture();
    await employees.add('002', 'José Muñoz');
    final previousIds = (await audit.list()).map((entry) => entry.id).toSet();
    await backups.restore(snapshot);
    final entries = await audit.list();
    expect(
      entries.map((entry) => entry.id).toSet().containsAll(previousIds),
      isTrue,
    );
    expect(entries.first.action, AuditAction.backupRestored);
    expect(entries.first.details['employees'], 1);
    expect((await employees.list()).single.number, '001');
  });

  test('El alta se revierte si no puede guardarse su auditoría', () async {
    final db = await database.open();
    await db.execute('''
      CREATE TRIGGER simulate_audit_failure BEFORE INSERT ON audit_entries
      WHEN NEW.action = 'employee_created'
      BEGIN SELECT RAISE(ABORT, 'simulated failure'); END
    ''');
    await expectLater(
      employees.add('001', 'Ana Pérez'),
      throwsA(isA<DatabaseException>()),
    );
    expect(await employees.list(), isEmpty);
  });

  test('No permite modificar ni eliminar acciones ya registradas', () async {
    final db = await database.open();
    await expectLater(
      db.update('audit_entries', {'actor': 'otro'}),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(
      db.delete('audit_entries'),
      throwsA(isA<DatabaseException>()),
    );
    expect((await audit.list()).single.actor, 'admin');
  });

  test('Pagina acciones sin repetir ni omitir registros', () async {
    final db = await database.open();
    await db.transaction((txn) async {
      for (var i = 0; i < 55; i++) {
        await writeAudit(
          txn,
          action: AuditAction.loginSucceeded,
          actor: 'admin',
        );
      }
    });
    final first = await audit.list();
    final second = await audit.list(beforeId: first.last.id);
    expect(first, hasLength(50));
    expect(second, hasLength(6));
    expect(
      [...first, ...second].map((entry) => entry.id).toSet(),
      hasLength(56),
    );
  });
}
