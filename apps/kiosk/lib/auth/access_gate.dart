import 'package:flutter/material.dart';

import '../admin/admin_shell.dart';
import '../admin/attendance_section.dart';
import '../admin/home_section.dart';
import '../admin/settings_section.dart';
import '../departments/department_store.dart';
import '../departments/departments_page.dart';
import '../reports/report_store.dart';

import '../attendance/attendance_page.dart';
import '../attendance/attendance_store.dart';
import '../attendance/attendance_review_page.dart';
import '../attendance/attendance_review_store.dart';
import '../vision/consent_page.dart';
import '../vision/consent_store.dart';
import '../vision/face_engine.dart';
import '../vision/face_template_store.dart';
import '../vision/face_enrollment_page.dart';
import '../vision/face_clock_page.dart';
import '../backup/backup_page.dart';
import '../backup/backup_service.dart';
import '../employees/employee_store.dart';
import '../employees/employees_page.dart';
import '../vision/vision_diagnostic_page.dart';
import 'admin_auth.dart';
import 'admin_login_page.dart';
import 'recovery_code_page.dart';
import 'rh_account_page.dart';
import 'organization_setup_page.dart';
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
            final faces = FaceTemplateStore(
              widget.attendance.database,
              cipher: FaceEngine(),
              authorizeEnrollment: auth.requireStaff,
              actor: () => auth.accountName,
            );
            return Navigator(
              key: ValueKey(
                '${auth.configured}-${auth.isAuthenticated}-${auth.organizationConfigured}-${auth.isAdministrator}-${auth.pendingRecoveryCode != null}',
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
                    return FaceClockPage(
                      organizationName: auth.organizationName,
                      faces: faces,
                      attendance: widget.attendance,
                      onOpenAdmin: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              AdminLoginPage(auth: auth, setup: false),
                        ),
                      ),
                    );
                  }
                  if (!auth.organizationConfigured) {
                    if (auth.isAdministrator) {
                      return OrganizationSetupPage(auth: auth);
                    }
                    return Scaffold(
                      appBar: AppBar(
                        title: const Text('Configuración pendiente'),
                      ),
                      body: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'Pide al administrador que configure la organización.',
                            ),
                            TextButton(
                              onPressed: auth.logout,
                              child: const Text('Volver al checador'),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  final reviews = AttendanceReviewStore(
                    widget.attendance.database,
                    authorize: auth.requireStaff,
                    actor: () => auth.accountName,
                  );
                  final departments = DepartmentStore(
                    widget.attendance.database,
                    authorize: auth.requireStaff,
                    actor: () => auth.accountName,
                  );
                  Future<void> open(Widget page) =>
                      Navigator.of(context)
                          .push(MaterialPageRoute<void>(builder: (_) => page));
                  return AdminShell(
                    organizationName: auth.organizationName,
                    accountName: auth.signedInName,
                    roleLabel: auth.isAdministrator
                        ? 'Administrador'
                        : 'Recursos Humanos',
                    onExit: auth.logout,
                    sections: [
                      AdminSection(
                        label: 'Inicio',
                        icon: Icons.home_outlined,
                        builder: (_) => HomeSection(
                          reports: ReportStore(
                            widget.attendance.database,
                            authorize: auth.requireStaff,
                          ),
                        ),
                      ),
                      AdminSection(
                        label: 'Empleados',
                        icon: Icons.people_outline,
                        builder: (_) => EmployeesPage(
                          store: widget.employees,
                          departments: departments,
                          onEnrollFace: (employee) async {
                            auth.requireStaff();
                            await Navigator.of(context).push(
                              MaterialPageRoute<bool>(
                                builder: (_) => FaceEnrollmentPage(
                                  employee: employee,
                                  faces: faces,
                                  consents: ConsentStore(
                                    widget.attendance.database,
                                    authorize: auth.requireStaff,
                                    actor: () => auth.accountName,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      AdminSection(
                        label: 'Departamentos',
                        icon: Icons.account_tree_outlined,
                        builder: (_) => DepartmentsPage(store: departments),
                      ),
                      AdminSection(
                        label: 'Asistencia',
                        icon: Icons.schedule_outlined,
                        builder: (_) => AttendanceSection(
                          review: (_) => AttendanceReviewPage(store: reviews),
                          manual: (_) => AttendancePage(
                            employees: widget.employees,
                            attendance: widget.attendance,
                          ),
                        ),
                      ),
                      if (auth.isAdministrator)
                        AdminSection(
                          label: 'Configuración',
                          icon: Icons.settings_outlined,
                          builder: (_) => SettingsSection(
                            groups: [
                              SettingsGroup('Accesos', [
                                SettingsEntry(
                                  title: 'Cuentas de RH',
                                  description:
                                      'Crear el acceso del personal de RH.',
                                  icon: Icons.person_add_alt_outlined,
                                  onOpen: () => open(RhAccountPage(auth: auth)),
                                ),
                                SettingsEntry(
                                  title: 'Código de recuperación',
                                  description: 'Generar un código nuevo para recuperar el acceso sin internet.',
                                  icon: Icons.key_outlined,
                                  onOpen: auth.rotateRecoveryCode,
                                ),
                              ]),
                              SettingsGroup('Datos', [
                                SettingsEntry(
                                  title: 'Respaldos',
                                  description: 'Guardar o restaurar los datos de la tablet.',
                                  icon: Icons.save_outlined,
                                  onOpen: () async {
                                    auth.requireAdmin();
                                    await open(
                                      BackupPage(service: widget.backups),
                                    );
                                  },
                                ),
                                SettingsEntry(
                                  title: 'Consentimientos',
                                  description: 'Folios de los documentos firmados para el uso del rostro.',
                                  icon: Icons.assignment_outlined,
                                  onOpen: () async {
                                    auth.requireAdmin();
                                    final consentStore = ConsentStore(
                                      widget.attendance.database,
                                      authorize: auth.requireAdmin,
                                      actor: () => auth.administratorName,
                                    );
                                    await open(
                                      ConsentPage(
                                        store: consentStore,
                                        onOpenFaceCheck: (employeeNumber) {
                                          auth.requireAdmin();
                                          open(
                                            VisionDiagnosticPage(
                                              employeeNumber: employeeNumber,
                                              consentStore: consentStore,
                                            ),
                                          );
                                        },
                                      ),
                                    );
                                  },
                                ),
                              ]),
                              if (widget.audit != null)
                                SettingsGroup('Registro', [
                                  SettingsEntry(
                                    title: 'Historial de acciones',
                                    description: 'Cambios y accesos registrados en la tablet.',
                                    icon: Icons.history,
                                    onOpen: () =>
                                        open(AuditPage(store: widget.audit!)),
                                  ),
                                ]),
                              SettingsGroup('Avanzado', [
                                SettingsEntry(
                                  title: 'Diagnóstico de cámara',
                                  description: 'Comprobar que la cámara detecta rostros.',
                                  icon: Icons.videocam_outlined,
                                  onOpen: () async {
                                    auth.requireAdmin();
                                    await open(const VisionDiagnosticPage());
                                  },
                                ),
                              ]),
                            ],
                          ),
                        ),
                    ],
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
