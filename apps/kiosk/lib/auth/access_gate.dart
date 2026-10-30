import 'package:flutter/material.dart';

import '../attendance/attendance_page.dart';
import '../attendance/attendance_store.dart';
import '../backup/backup_page.dart';
import '../backup/backup_service.dart';
import '../employees/employee_store.dart';
import '../employees/employees_page.dart';
import 'admin_auth.dart';
import 'admin_login_page.dart';
import 'recovery_code_page.dart';
import '../audit/audit_page.dart';
import '../audit/audit_store.dart';

class AccessGate extends StatefulWidget {
  const AccessGate({
    super.key,
    required this.auth,
    required this.employees,
    required this.attendance,
    required this.backups,
    this.audit,
  });
  final AdminAuth auth;
  final EmployeeStore employees;
  final AttendanceStore attendance;
  final BackupService backups;
  final AuditStore? audit;

  @override
  State<AccessGate> createState() => _AccessGateState();
}

class _AccessGateState extends State<AccessGate> with WidgetsBindingObserver {
  bool _ready = false;
  String? _error;
  DateTime? _backgroundAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    setState(() {
      _ready = false;
      _error = null;
    });
    try {
      await widget.auth.initialize();
      if (mounted) {
        setState(() => _ready = true);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No se pudo abrir la configuración de acceso.');
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _backgroundAt = DateTime.now();
    }
    if (state == AppLifecycleState.resumed) {
      final backgroundAt = _backgroundAt;
      if (backgroundAt != null &&
          DateTime.now().difference(backgroundAt) >=
              const Duration(minutes: 1)) {
        widget.auth.logout();
      }
      _backgroundAt = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Scaffold(
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!),
                    TextButton(
                      onPressed: _initialize,
                      child: const Text('Volver a intentar'),
                    ),
                  ],
                ),
        ),
      );
    }
    return Listener(
      onPointerDown: (_) => widget.auth.touch(),
      child: Focus(
        onKeyEvent: (_, _) {
          widget.auth.touch();
          return KeyEventResult.ignored;
        },
        child: ListenableBuilder(
          listenable: widget.auth,
          builder: (context, _) {
            final auth = widget.auth;
            return Navigator(
              key: ValueKey(
                '${auth.configured}-${auth.isAuthenticated}-${auth.pendingRecoveryCode != null}',
              ),
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (context) {
                  final recoveryCode = auth.pendingRecoveryCode;
                  if (recoveryCode != null) {
                    return RecoveryCodePage(
                      code: recoveryCode,
                      onContinue: auth.acknowledgeRecoveryCode,
                    );
                  }
                  if (!auth.configured) {
                    return AdminLoginPage(auth: auth, setup: true);
                  }
                  if (!auth.isAuthenticated) {
                    return AttendancePage(
                      employees: widget.employees,
                      attendance: widget.attendance,
                      onOpenAdmin: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              AdminLoginPage(auth: auth, setup: false),
                        ),
                      ),
                    );
                  }
                  return EmployeesPage(
                    store: widget.employees,
                    onRotateRecoveryCode: auth.rotateRecoveryCode,
                    onOpenAudit: widget.audit == null
                        ? null
                        : () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => AuditPage(store: widget.audit!),
                            ),
                          ),
                    onLogout: auth.logout,
                    onOpenAttendance: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AttendancePage(
                          employees: widget.employees,
                          attendance: widget.attendance,
                        ),
                      ),
                    ),
                    onOpenBackup: () async {
                      auth.requireAdmin();
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => BackupPage(service: widget.backups),
                        ),
                      );
                    },
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
