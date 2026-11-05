import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../admin/admin_shell.dart';
import '../payroll/payroll.dart';
import '../theme/app_theme.dart';
import 'department_store.dart';
import 'schedule.dart';

/// Departamentos con su horario. Las checadas se comparan contra el horario
/// del departamento de cada empleado.
class DepartmentsPage extends StatefulWidget {
  const DepartmentsPage({super.key, required this.store});
  final DepartmentStore store;

  @override
  State<DepartmentsPage> createState() => _DepartmentsPageState();
}

class _DepartmentsPageState extends State<DepartmentsPage> {
  List<Department> _departments = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final departments = await widget.store.list();
      if (mounted) setState(() => _departments = departments);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No se pudieron cargar los departamentos.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit([Department? department]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) =>
          _DepartmentDialog(store: widget.store, department: department),
    );
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final body = ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Cada empleado toma el horario de su departamento. Las checadas fuera de horario pasan a revisión.',
                style: text.bodyMedium?.copyWith(color: AppColors.muted),
              ),
            ),
            const SizedBox(width: 16),
            FilledButton.icon(
              onPressed: _loading ? null : _edit,
              icon: const Icon(Icons.add, size: 20),
              label: const Text('Nuevo departamento'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null) ...[
          Text(_error!),
          TextButton(onPressed: _load, child: const Text('Volver a intentar')),
        ] else if (_departments.isEmpty)
          const Text(
            'Aún no hay departamentos. Crea el primero para poder asignar horarios a los empleados.',
          )
        else
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              children: [
                for (var i = 0; i < _departments.length; i++) ...[
                  if (i > 0) const Divider(),
                  _row(context, _departments[i]),
                ],
              ],
            ),
          ),
      ],
    );
    if (EmbeddedInShell.of(context)) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('Departamentos')),
      body: SafeArea(child: body),
    );
  }

  Widget _row(BuildContext context, Department department) {
    final text = Theme.of(context).textTheme;
    final people = department.employeeCount == 1
        ? '1 empleado'
        : '${department.employeeCount} empleados';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  department.name,
                  style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  '${formatMinutes(department.entryMinutes)} a ${formatMinutes(department.exitMinutes)} · ${WorkDays.describe(department.workDays)} · tolerancia ${department.toleranceMinutes} min${department.dailyWageCents == null ? '' : ' · ${formatMoney(department.dailyWageCents!)} diarios'} · $people',
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _edit(department),
            child: const Text('Editar'),
          ),
        ],
      ),
    );
  }
}

class _DepartmentDialog extends StatefulWidget {
  const _DepartmentDialog({required this.store, this.department});
  final DepartmentStore store;
  final Department? department;

  @override
  State<_DepartmentDialog> createState() => _DepartmentDialogState();
}

class _DepartmentDialogState extends State<_DepartmentDialog> {
  static const _tolerances = [0, 5, 10, 15, 20, 30, 45, 60];
  late final _name = TextEditingController(text: widget.department?.name);
  late final _wage = TextEditingController(
    text: widget.department?.dailyWageCents == null
        ? ''
        : (widget.department!.dailyWageCents! / 100).toStringAsFixed(2),
  );
  late int _entry = widget.department?.entryMinutes ?? 8 * 60;
  late int _exit = widget.department?.exitMinutes ?? 17 * 60;
  late int _tolerance = widget.department?.toleranceMinutes ?? 10;
  late int _days = widget.department?.workDays ?? WorkDays.mondayToFriday;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _wage.dispose();
    super.dispose();
  }

  Future<void> _pick(bool entry) async {
    final current = entry ? _entry : _exit;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
      initialEntryMode: TimePickerEntryMode.input,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null) return;
    setState(() {
      final minutes = picked.hour * 60 + picked.minute;
      if (entry) {
        _entry = minutes;
      } else {
        _exit = minutes;
      }
    });
  }

  Future<void> _save() async {
    final wage = parseMoney(_wage.text);
    if (_wage.text.trim().isNotEmpty && wage == null) {
      setState(() => _error = 'Escribe el salario diario como 350 o 350.50.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.save(
        id: widget.department?.id,
        name: _name.text,
        entryMinutes: _entry,
        exitMinutes: _exit,
        toleranceMinutes: _tolerance,
        workDays: _days,
        dailyWageCents: wage,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on DepartmentRuleError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No se pudo guardar. Vuelve a intentarlo.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final overnight = _exit < _entry;
    return AlertDialog(
      title: Text(
        widget.department == null
            ? 'Nuevo departamento'
            : 'Editar departamento',
      ),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              enabled: !_saving,
              autofocus: widget.department == null,
              maxLength: 80,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Nombre',
                hintText: 'Producción, Almacén, Cocina…',
                counterText: '',
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _TimeField(
                    label: 'Entrada',
                    minutes: _entry,
                    onTap: _saving ? null : () => _pick(true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _TimeField(
                    label: 'Salida',
                    minutes: _exit,
                    onTap: _saving ? null : () => _pick(false),
                  ),
                ),
              ],
            ),
            if (overnight)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Turno nocturno: la salida es al día siguiente.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 16),
            Text(
              'Días laborables',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (var i = 0; i < 7; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  Expanded(
                    child: _DayToggle(
                      label: WorkDays.letters[i],
                      tooltip: WorkDays.names[i],
                      selected: _days & (1 << i) != 0,
                      onTap: _saving
                          ? null
                          : () => setState(() => _days ^= 1 << i),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _tolerances.contains(_tolerance)
                        ? _tolerance
                        : 10,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Tolerancia'),
                    items: [
                      for (final minutes in _tolerances)
                        DropdownMenuItem(
                          value: minutes,
                          child: Text(
                            minutes == 0 ? 'Sin tolerancia' : '$minutes min',
                          ),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _tolerance = value ?? 10),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _wage,
                    enabled: !_saving,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Salario diario',
                      hintText: 'Opcional',
                      prefixText: '\$ ',
                    ),
                  ),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Guardando…' : 'Guardar'),
        ),
      ],
    );
  }
}

class _TimeField extends StatelessWidget {
  const _TimeField({required this.label, required this.minutes, this.onTap});
  final String label;
  final int minutes;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(6),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: const Icon(Icons.schedule, size: 20),
      ),
      child: Text(
        formatMinutes(minutes),
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
      ),
    ),
  );
}

class _DayToggle extends StatelessWidget {
  const _DayToggle({
    required this.label,
    required this.tooltip,
    required this.selected,
    this.onTap,
  });
  final String label;
  final String tooltip;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      selected: selected,
      button: true,
      label: tooltip,
      child: Material(
        color: selected ? AppColors.ink : AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: selected ? AppColors.ink : AppColors.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: SizedBox(
            height: 44,
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : AppColors.muted,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
