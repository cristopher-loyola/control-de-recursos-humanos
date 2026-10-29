import 'package:flutter/material.dart';

import 'employee_store.dart';
import 'employee_validation.dart';

class EmployeesPage extends StatefulWidget {
  const EmployeesPage({
    super.key,
    required this.store,
    this.onOpenAttendance,
    this.onOpenBackup,
  });
  final EmployeeStore store;
  final VoidCallback? onOpenAttendance;
  final Future<void> Function()? onOpenBackup;

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
    appBar: AppBar(
      title: const Text('Control de Recursos Humanos'),
      actions: [
        if (widget.onOpenBackup != null)
          IconButton(
            tooltip: 'Respaldos',
            icon: const Icon(Icons.backup_outlined),
            onPressed: _saving || _loading
                ? null
                : () async {
                    await widget.onOpenBackup!();
                    if (mounted) {
                      await _load();
                    }
                  },
          ),
        if (widget.onOpenAttendance != null)
          TextButton.icon(
            onPressed: _saving ? null : widget.onOpenAttendance,
            icon: const Icon(Icons.access_time),
            label: const Text('Asistencia'),
          ),
      ],
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
