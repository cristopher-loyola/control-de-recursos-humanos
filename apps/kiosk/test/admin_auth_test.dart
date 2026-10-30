import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/auth/admin_auth.dart';
import 'package:kiosk/auth/password_hasher.dart';
import 'package:kiosk/backup/backup_service.dart';
import 'package:kiosk/database/local_database.dart';
import 'package:kiosk/employees/employee_store.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Solo las pruebas usan este sustituto; la aplicación utiliza PBKDF2.
class TestHasher extends PasswordHasher {
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
  late DateTime now;
  const password = 'Una frase segura 2026';

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('rh_auth_test_');
    database = LocalDatabase(
      filePath: path.join(temp.path, 'test.db'),
      factory: databaseFactoryFfi,
    );
    now = DateTime(2026, 10, 29, 8);
    auth = AdminAuth(database, hasher: TestHasher(), clock: () => now);
    await auth.initialize();
  });

  tearDown(() async {
    auth.dispose();
    await database.close();
    await temp.delete(recursive: true);
  });

  test(
    'Crea una cuenta única, sin guardar la contraseña y sin sesión persistente',
    () async {
      expect(auth.configured, isFalse);
      await auth.create('Admin', password);
      expect(auth.isAuthenticated, isTrue);
      final rows = await (await database.open()).query('administrator');
      expect(rows.single['username'], 'admin');
      expect(rows.single.values, isNot(contains(password)));
      expect((rows.single['salt'] as List).length, 16);
      expect((rows.single['password_hash'] as List).length, 32);
      await expectLater(
        auth.create('otra', password),
        throwsA(isA<AuthenticationError>()),
      );
      auth.dispose();
      await database.close();
      auth = AdminAuth(database, hasher: TestHasher(), clock: () => now);
      await auth.initialize();
      expect(auth.configured, isTrue);
      expect(auth.isAuthenticated, isFalse);
      await auth.login('ADMIN', password);
      expect(auth.isAuthenticated, isTrue);
    },
  );

  test(
    'Bloquea operaciones administrativas sin sesión y tras expirar',
    () async {
      final employees = EmployeeStore(
        database: database,
        authorize: auth.requireAdmin,
      );
      final backups = BackupService(database, authorize: auth.requireAdmin);
      await expectLater(
        employees.add('1', 'Ana'),
        throwsA(isA<AdminAccessRequired>()),
      );
      await expectLater(backups.capture(), throwsA(isA<AdminAccessRequired>()));
      await auth.create('admin', password);
      await employees.add('1', 'Ana');
      final snapshot = await backups.capture();
      auth.logout();
      await expectLater(
        backups.restore(snapshot),
        throwsA(isA<AdminAccessRequired>()),
      );
      await auth.login('admin', password);
      now = now.add(const Duration(minutes: 11));
      await expectLater(
        employees.add('2', 'José'),
        throwsA(isA<AdminAccessRequired>()),
      );
      expect(auth.isAuthenticated, isFalse);
      expect(await employees.list(), hasLength(1));
    },
  );

  test('Los intentos fallidos y el bloqueo permanecen al reabrir', () async {
    await auth.create('admin', password);
    auth.logout();
    for (var attempt = 0; attempt < 5; attempt++) {
      await expectLater(
        auth.login('admin', 'incorrecta'),
        throwsA(isA<AuthenticationError>()),
      );
    }
    auth.dispose();
    await database.close();
    auth = AdminAuth(database, hasher: TestHasher(), clock: () => now);
    await auth.initialize();
    await expectLater(
      auth.login('admin', password),
      throwsA(isA<AuthenticationError>()),
    );
    now = now.add(const Duration(minutes: 1, seconds: 1));
    await auth.login('admin', password);
    expect(auth.isAuthenticated, isTrue);
  });

  test('Restaurar un respaldo no sustituye ni elimina la cuenta', () async {
    await auth.create('admin', password);
    final employees = EmployeeStore(
      database: database,
      authorize: auth.requireAdmin,
    );
    final backups = BackupService(database, authorize: auth.requireAdmin);
    await employees.add('1', 'Ana');
    final snapshot = await backups.capture();
    await employees.add('2', 'José');
    await backups.restore(snapshot);
    auth.logout();
    await auth.login('admin', password);
    expect(auth.isAuthenticated, isTrue);
    expect(await employees.list(), hasLength(1));
  });

  test(
    'Rechaza contraseñas cortas y conserva exactamente los espacios',
    () async {
      await expectLater(
        auth.create('admin', 'corta'),
        throwsA(isA<AuthenticationError>()),
      );
      await auth.create('admin', '  Una frase segura  ');
      auth.logout();
      await expectLater(
        auth.login('admin', 'Una frase segura'),
        throwsA(isA<AuthenticationError>()),
      );
      await auth.login('admin', '  Una frase segura  ');
    },
  );

  test('El usuario incorrecto no abre la sesión', () async {
    await auth.create('admin', password);
    auth.logout();
    await expectLater(
      auth.login('otro', password),
      throwsA(isA<AuthenticationError>()),
    );
    expect(auth.isAuthenticated, isFalse);
  });

  test(
    'El algoritmo real permite verificar la contraseña después de reiniciar',
    () async {
      auth.dispose();
      auth = AdminAuth(database);
      await auth.create('admin', password);
      auth.dispose();
      await database.close();
      auth = AdminAuth(database);
      await auth.initialize();
      await auth.login('admin', password);
      expect(auth.isAuthenticated, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
