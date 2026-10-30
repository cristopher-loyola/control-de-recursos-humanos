import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/audit/audit_store.dart';
import 'package:kiosk/auth/admin_auth.dart';
import 'package:kiosk/backup/backup_service.dart';
import 'package:kiosk/database/local_database.dart';
import 'package:kiosk/employees/employee_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'RH gestiona empleados pero no funciones reservadas al administrador',
    () async {
      final database = LocalDatabase(
        filePath: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final auth = AdminAuth(database);
      addTearDown(() async {
        auth.dispose();
        await database.close();
      });
      final employees = EmployeeStore(
        database: database,
        authorize: auth.requireStaff,
        actor: () => auth.accountName,
      );
      final backups = BackupService(database, authorize: auth.requireAdmin);
      final audit = AuditStore(database, authorize: auth.requireAdmin);

      await auth.initialize();
      await auth.create('admin', 'contraseña administrativa segura');
      auth.acknowledgeRecoveryCode();
      await auth.saveOrganization('Organización piloto');
      expect(auth.organizationConfigured, isTrue);
      await auth.createRhAccount('rrhh', 'contraseña de recursos humanos');
      auth.logout();

      await auth.login('rrhh', 'contraseña de recursos humanos');
      expect(auth.isHumanResources, isTrue);
      expect(auth.isAdministrator, isFalse);
      await employees.add('101', 'Empleado de prueba');
      expect((await employees.list()).single.number, '101');
      expect(() => auth.requireAdmin(), throwsA(isA<AdminAccessRequired>()));
      await expectLater(
        auth.saveOrganization('Otra organización'),
        throwsA(isA<AdminAccessRequired>()),
      );
      await expectLater(backups.capture(), throwsA(isA<AdminAccessRequired>()));
      await expectLater(audit.list(), throwsA(isA<AdminAccessRequired>()));
      await expectLater(
        auth.createRhAccount('otro', 'otra contraseña segura'),
        throwsA(isA<AdminAccessRequired>()),
      );

      auth.logout();
      await auth.login('admin', 'contraseña administrativa segura');
      expect(auth.isAdministrator, isTrue);
      final entries = await audit.list();
      expect(
        entries.any((entry) => entry.action == AuditAction.rhAccountCreated),
        isTrue,
      );
      expect(
        entries.any(
          (entry) => entry.action == AuditAction.organizationConfigured,
        ),
        isTrue,
      );
      expect(
        entries.any(
          (entry) =>
              entry.action == AuditAction.employeeCreated &&
              entry.actor == 'rrhh',
        ),
        isTrue,
      );
    },
  );
}
