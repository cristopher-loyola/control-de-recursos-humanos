import 'package:flutter/material.dart';

import 'attendance/attendance_store.dart';
import 'audit/audit_store.dart';
import 'auth/access_gate.dart';
import 'auth/admin_auth.dart';
import 'backup/backup_service.dart';
import 'database/local_database.dart';
import 'employees/employee_store.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final database = LocalDatabase();
  final auth = AdminAuth(database);
  runApp(MyApp(auth: auth, database: database));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.auth, required this.database});
  final AdminAuth auth;
  final LocalDatabase database;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Control de Recursos Humanos',
    debugShowCheckedModeBanner: false,
    theme: createAppTheme(),
    home: AccessGate(
      auth: auth,
      employees: EmployeeStore(
        database: database,
        authorize: auth.requireAdmin,
        actor: () => auth.administratorName,
      ),
      attendance: AttendanceStore(database),
      backups: BackupService(
        database,
        authorize: auth.requireAdmin,
        actor: () => auth.administratorName,
      ),
      audit: AuditStore(database, authorize: auth.requireAdmin),
    ),
  );
}
