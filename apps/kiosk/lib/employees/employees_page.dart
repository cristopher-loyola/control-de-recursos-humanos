import 'package:flutter/material.dart';

import 'employee_store.dart';
import 'employee_validation.dart';

class EmployeesPage extends StatefulWidget {
  const EmployeesPage({
    super.key,
    required this.store,
    this.onOpenAttendance,
    this.onOpenBackup,
    this.onLogout,
    this.onOpenAudit,
    this.onOpenVisionDiagnostic,
    this.onOpenConsents,
    this.onOpenAttendanceReview,
    this.onRotateRecoveryCode,
    this.onCreateRhAccount,
  });
  final EmployeeStore store;
  final VoidCallback? onOpenAttendance;
  final Future<void> Function()? onOpenBackup;
  final VoidCallback? onLogout;
  final VoidCallback? onOpenAudit;
  final VoidCallback? onOpenVisionDiagnostic;
  final VoidCallback? onOpenConsents;
  final VoidCallback? onOpenAttendanceReview;
  final Future<void> Function()? onRotateRecoveryCode;
  final VoidCallback? onCreateRhAccount;

  @override
  State<EmployeesPage> createState() => _EmployeesPageState();
}

class _EmployeesPageState extends State<EmployeesPage> {
  final _form = GlobalKey<FormState>();
  final _number = TextEditingController();
  final _name = TextEditingController();
  List<Employee> _employees = [];
  bool _loading = true;
  bool _saving = false;
  bool _rotatingRecoveryCode = false;
  String? _loadError;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final employees = await widget.store.list();
      if (mounted) {
        setState(() => _employees = employees);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _loadError =
              'No se pudieron cargar los empleados. Intenta nuevamente.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) {
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await widget.store.add(_number.text, _name.text);
      if (!mounted) {
        return;
      }
      _number.clear();
      _name.clear();
      _form.currentState!.reset();
      setState(() => _message = 'Empleado guardado en esta tablet.');
      await _load();
    } on DuplicateEmployee {
      if (mounted) {
        setState(() => _message = 'Ya existe un empleado con ese número.');
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'No se pudo guardar. Tus datos siguen en el formulario; vuelve a intentarlo.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  void dispose() {
    _number.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    drawer: Drawer(
      child: Builder(
        builder: (drawerContext) => SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Secciones',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Ocultar menú',
                      onPressed: () => Navigator.of(drawerContext).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text('Elige la tarea que quieres realizar.'),
              ),
              ListTile(
                leading: const Icon(Icons.people_outline),
                title: const Text('Empleados'),
                subtitle: const Text('Registrar y consultar personal.'),
                selected: true,
                onTap: () => Navigator.of(drawerContext).pop(),
              ),
              if (widget.onOpenAttendanceReview != null)
                ListTile(
                  leading: const Icon(Icons.fact_check_outlined),
                  title: const Text('Revisar asistencia'),
                  subtitle: const Text('Aprobar o rechazar checadas manuales.'),
                  onTap: _saving || _loading
                      ? null
                      : () {
                          Navigator.of(drawerContext).pop();
                          widget.onOpenAttendanceReview!();
                        },
                ),
              if (widget.onOpenAttendance != null)
                ListTile(
                  leading: const Icon(Icons.access_time),
                  title: const Text('Asistencia'),
                  subtitle: const Text('Consultar entradas y salidas.'),
                  onTap: _saving
                      ? null
                      : () {
                          Navigator.of(drawerContext).pop();
                          widget.onOpenAttendance!();
                        },
                ),
              if (widget.onOpenVisionDiagnostic != null)
                ListTile(
                  leading: const Icon(Icons.camera_alt_outlined),
                  title: const Text('Diagnóstico de cámara'),
                  subtitle: const Text(
                    'Comprobar la detección local de rostros.',
                  ),
                  onTap: _saving || _loading
                      ? null
                      : () {
                          Navigator.of(drawerContext).pop();
                          widget.onOpenVisionDiagnostic!();
                        },
                ),
              if (widget.onOpenConsents != null)
                ListTile(
                  leading: const Icon(Icons.assignment_turned_in_outlined),
                  title: const Text('Consentimientos'),
                  subtitle: const Text(
                    'Registrar folios de documentos firmados.',
                  ),
                  onTap: _saving || _loading
                      ? null
                      : () {
                          Navigator.of(drawerContext).pop();
                          widget.onOpenConsents!();
                        },
                ),
              if (widget.onCreateRhAccount != null ||
                  widget.onRotateRecoveryCode != null ||
                  widget.onOpenAudit != null ||
                  widget.onOpenBackup != null)
                const Divider(height: 32),
              if (widget.onCreateRhAccount != null)
                ListTile(
                  leading: const Icon(Icons.person_add_alt_1_outlined),
                  title: const Text('Cuentas de RH'),
                  subtitle: const Text('Crear el acceso del personal de RH.'),
                  onTap: _saving || _loading
                      ? null
                      : () {
                          Navigator.of(drawerContext).pop();
                          widget.onCreateRhAccount!();
                        },
                ),
              if (widget.onRotateRecoveryCode != null)
                ListTile(
                  leading: const Icon(Icons.key_outlined),
                  title: const Text('Código de recuperación'),
                  subtitle: const Text(
                    'Generar un código nuevo para recuperar el acceso.',
                  ),
                  onTap: _saving || _loading || _rotatingRecoveryCode
                      ? null
                      : () async {
                          Navigator.of(drawerContext).pop();
                          setState(() => _rotatingRecoveryCode = true);
                          try {
                            await widget.onRotateRecoveryCode!();
                          } catch (_) {
                            if (mounted) {
                              setState(
                                () => _message = 'No se pudo generar el código. Vuelve a intentarlo.',
                              );
                            }
                          } finally {
                            if (mounted) {
                              setState(() => _rotatingRecoveryCode = false);
                            }
                          }
                        },
                ),
              if (widget.onOpenAudit != null)
                ListTile(
                  leading: const Icon(Icons.history),
                  title: const Text('Historial de acciones'),
                  subtitle: const Text(
                    'Consultar cambios y accesos registrados.',
                  ),
                  onTap: _saving || _loading
                      ? null
                      : () {
                          Navigator.of(drawerContext).pop();
                          widget.onOpenAudit!();
                        },
                ),
              if (widget.onOpenBackup != null)
                ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: const Text('Respaldos'),
                  subtitle: const Text(
                    'Guardar o restaurar los datos de la tablet.',
                  ),
                  onTap: _saving || _loading
                      ? null
                      : () async {
                          Navigator.of(drawerContext).pop();
                          await widget.onOpenBackup!();
                          if (mounted) {
                            await _load();
                          }
                        },
                ),
              if (widget.onLogout != null) ...[
                const Divider(height: 32),
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const Text('Cerrar sesión'),
                  subtitle: const Text('Volver al checador de asistencia.'),
                  onTap: _saving
                      ? null
                      : () {
                          Navigator.of(drawerContext).pop();
                          widget.onLogout!();
                        },
                ),
              ],
            ],
          ),
        ),
      ),
    ),
    appBar: AppBar(
      title: const Text('Control de Recursos Humanos'),
      leading: Builder(
        builder: (scaffoldContext) => IconButton(
          tooltip: 'Abrir menú',
          onPressed: () => Scaffold.of(scaffoldContext).openDrawer(),
          icon: const Icon(Icons.menu),
        ),
      ),
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 850),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Empleados',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Registra y consulta empleados en esta tablet, sin internet.',
              ),
              const SizedBox(height: 24),
              Form(
                key: _form,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _number,
                      enabled: !_saving,
                      maxLength: 30,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Número de empleado',
                        border: OutlineInputBorder(),
                      ),
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      validator: validateEmployeeNumber,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _name,
                      enabled: !_saving,
                      maxLength: 120,
                      decoration: const InputDecoration(
                        labelText: 'Nombre completo',
                        border: OutlineInputBorder(),
                      ),
                      textCapitalization: TextCapitalization.words,
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      validator: validateEmployeeName,
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _saving || _loading || _loadError != null
                          ? null
                          : _save,
                      child: Text(_saving ? 'Guardando…' : 'Guardar empleado'),
                    ),
                  ],
                ),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Semantics(liveRegion: true, child: Text(_message!)),
                ),
              const Divider(height: 40),
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else if (_loadError != null) ...[
                Text(_loadError!),
                TextButton(
                  onPressed: _load,
                  child: const Text('Volver a intentar'),
                ),
              ] else ...[
                Text(
                  'Empleados registrados: ${_employees.length}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                if (_employees.isEmpty)
                  const Text('Aún no hay empleados registrados.'),
                for (final employee in _employees)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(employee.name),
                      subtitle: Text('Número: ${employee.number}'),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
