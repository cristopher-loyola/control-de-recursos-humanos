import 'package:flutter/material.dart';

import 'attendance/attendance_page.dart';
import 'attendance/attendance_store.dart';
import 'backup/backup_page.dart';
import 'backup/backup_service.dart';
import 'database/local_database.dart';
import 'employees/employee_store.dart';
import 'employees/employees_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final database = LocalDatabase();
  runApp(
    MyApp(
      store: EmployeeStore(database: database),
      attendanceStore: AttendanceStore(database),
      backupService: BackupService(database),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    required this.store,
    this.attendanceStore,
    this.backupService,
  });
  final EmployeeStore store;
  final AttendanceStore? attendanceStore;
  final BackupService? backupService;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Control de Recursos Humanos',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2948A8)),
    ),
    home: Builder(
      builder: (context) => EmployeesPage(
        store: store,
        onOpenAttendance: attendanceStore == null
            ? null
            : () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => AttendancePage(
                    employees: store,
                    attendance: attendanceStore!,
                  ),
                ),
              ),
        onOpenBackup: backupService == null
            ? null
            : () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => BackupPage(service: backupService!),
                  ),
                );
              },
      ),
    ),
  );
}
