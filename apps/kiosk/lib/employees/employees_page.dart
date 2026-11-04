import 'package:flutter/material.dart';

import '../admin/admin_shell.dart';
import '../departments/department_store.dart';
import '../theme/app_theme.dart';
import 'employee_store.dart';
import 'employee_validation.dart';

/// Alta rápida en un renglón y lista con búsqueda. Al guardar se abre de
/// inmediato el registro de rostro del mismo empleado.
class EmployeesPage extends StatefulWidget {
  const EmployeesPage({
    super.key,
    required this.store,
    this.departments,
    this.onEnrollFace,
  });
  final EmployeeStore store;

  /// Si se indica, el alta pide departamento y la lista permite cambiarlo.
  final DepartmentStore? departments;
  final Future<void> Function(Employee)? onEnrollFace;

  @override
  State<EmployeesPage> createState() => _EmployeesPageState();
}

class _EmployeesPageState extends State<EmployeesPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _search = TextEditingController();
  List<Employee> _employees = [];
  List<Department> _departments = [];
  int? _departmentId;
  bool _loading = true;
  bool _saving = false;
  String? _loadError;
  String? _message;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final employees = await widget.store.list();
      final departments = await widget.departments?.list() ?? <Department>[];
      if (mounted) {
        setState(() {
          _employees = employees;
          _departments = departments;
          if (!departments.any((d) => d.id == _departmentId)) {
            _departmentId = departments.length == 1
                ? departments.single.id
                : null;
          }
        });
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
    if (_departments.isNotEmpty && _departmentId == null) {
      setState(() => _message = 'Elige el departamento del empleado.');
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final name = _name.text.trim();
      final number = await widget.store.register(
        name,
        departmentId: _departmentId,
      );
      final employee = Employee(number: number, name: name);
      if (!mounted) {
        return;
      }
      _name.clear();
      _form.currentState!.reset();
      setState(() => _message = '$name quedó registrado con el No. $number.');
      await _load();
      if (mounted && widget.onEnrollFace != null) {
        await _openEnrollment(employee);
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
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _openEnrollment(Employee employee) async {
    setState(() => _saving = true);
    try {
      await widget.onEnrollFace!(employee);
      if (mounted) await _load();
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'El empleado está guardado. No se pudo abrir la captura del rostro; vuelve a intentarlo.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _changeDepartment(Employee employee) async {
    final chosen = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Departamento de ${employee.name}'),
        children: [
          for (final department in _departments)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(department.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  department.id == employee.departmentId
                      ? '${department.name} (actual)'
                      : department.name,
                ),
              ),
            ),
        ],
      ),
    );
    if (chosen == null || chosen == employee.departmentId) return;
    setState(() => _saving = true);
    try {
      await widget.store.setDepartment(employee.number, chosen);
      await _load();
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'No se pudo cambiar el departamento.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<Employee> get _visible {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return _employees;
    return _employees
        .where(
          (employee) =>
              employee.name.toLowerCase().contains(query) ||
              employee.number.contains(query),
        )
        .toList();
  }

  Widget _newEmployeeForm(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    // Solo informativo: el número definitivo lo asigna la base al guardar.
    final next =
        _employees.fold<int>(0, (top, e) {
          final value = int.tryParse(e.number) ?? 0;
          return value > top ? value : top;
        }) +
        1;
    final number = InputDecorator(
      decoration: const InputDecoration(labelText: 'Número'),
      child: Text(
        _loading ? '…' : '$next',
        style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
      ),
    );
    final name = TextFormField(
      controller: _name,
      enabled: !_saving,
      maxLength: 120,
      decoration: const InputDecoration(
        labelText: 'Nombre completo',
        counterText: '',
      ),
      textCapitalization: TextCapitalization.words,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: validateEmployeeName,
      onFieldSubmitted: (_) => _save(),
    );
    final department = DropdownButtonFormField<int>(
      initialValue: _departmentId,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Departamento'),
      items: [
        for (final department in _departments)
          DropdownMenuItem(value: department.id, child: Text(department.name)),
      ],
      onChanged: _saving
          ? null
          : (value) => setState(() => _departmentId = value),
    );
    final hasDepartments = _departments.isNotEmpty;
    final save = FilledButton(
      onPressed: _saving || _loading || _loadError != null ? null : _save,
      child: Text(_saving ? 'Guardando…' : 'Guardar empleado'),
    );
    return Form(
      key: _form,
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 104, child: number),
                const SizedBox(width: 12),
                Expanded(child: name),
                if (hasDepartments) ...[
                  const SizedBox(width: 12),
                  SizedBox(width: 220, child: department),
                ],
                const SizedBox(width: 12),
                Padding(padding: const EdgeInsets.only(top: 4), child: save),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                number,
                const SizedBox(height: 12),
                name,
                if (hasDepartments) ...[const SizedBox(height: 12), department],
                const SizedBox(height: 12),
                save,
              ],
            ),
    );
  }

  Widget _employeeRow(BuildContext context, Employee employee) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  employee.name,
                  style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text.rich(
                  TextSpan(
                    style: text.bodySmall,
                    children: [
                      TextSpan(text: 'No. ${employee.number} · '),
                      if (widget.departments != null)
                        TextSpan(
                          text: employee.departmentName == null
                              ? 'Sin departamento · '
                              : '${employee.departmentName} · ',
                          style: employee.departmentName == null
                              ? const TextStyle(color: AppColors.danger)
                              : null,
                        ),
                      TextSpan(
                        text: employee.hasFace
                            ? 'Rostro registrado'
                            : 'Rostro pendiente',
                        style: employee.hasFace
                            ? null
                            : const TextStyle(color: AppColors.danger),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_departments.isNotEmpty)
            TextButton(
              onPressed: _saving || _loading
                  ? null
                  : () => _changeDepartment(employee),
              child: Text(
                employee.departmentName == null
                    ? 'Asignar departamento'
                    : 'Cambiar departamento',
              ),
            ),
          if (widget.onEnrollFace != null)
            employee.hasFace
                ? TextButton(
                    onPressed: _saving || _loading
                        ? null
                        : () => _openEnrollment(employee),
                    child: const Text('Actualizar rostro'),
                  )
                : OutlinedButton(
                    onPressed: _saving || _loading
                        ? null
                        : () => _openEnrollment(employee),
                    child: const Text('Registrar rostro'),
                  ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final visible = _visible;
    final body = ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Nuevo empleado', style: text.titleMedium),
        const SizedBox(height: 12),
        if (widget.departments != null && !_loading && _departments.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Todavía no hay departamentos. Puedes registrar al empleado, pero sus checadas irán a revisión hasta que tenga uno.',
              style: text.bodySmall,
            ),
          ),
        _newEmployeeForm(context),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(liveRegion: true, child: Text(_message!)),
          ),
        const SizedBox(height: 32),
        Row(
          children: [
            Expanded(
              child: Text(
                _loading ? 'Empleados' : 'Empleados (${_employees.length})',
                style: text.titleMedium,
              ),
            ),
            SizedBox(
              width: 280,
              child: TextField(
                controller: _search,
                decoration: const InputDecoration(
                  hintText: 'Buscar por nombre o número',
                  prefixIcon: Icon(Icons.search, size: 20),
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_loadError != null) ...[
          Text(_loadError!),
          TextButton(onPressed: _load, child: const Text('Volver a intentar')),
        ] else if (_employees.isEmpty)
          const Text('Aún no hay empleados registrados.')
        else if (visible.isEmpty)
          const Text('Ningún empleado coincide con la búsqueda.')
        else
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              children: [
                for (var i = 0; i < visible.length; i++) ...[
                  if (i > 0) const Divider(),
                  _employeeRow(context, visible[i]),
                ],
              ],
            ),
          ),
      ],
    );
    if (EmbeddedInShell.of(context)) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('Empleados')),
      body: SafeArea(child: body),
    );
  }
}
