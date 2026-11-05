import 'package:flutter/material.dart';

import '../admin/admin_shell.dart';
import '../departments/department_store.dart';
import '../theme/app_theme.dart';
import 'holiday_store.dart';

const _months = [
  'Enero',
  'Febrero',
  'Marzo',
  'Abril',
  'Mayo',
  'Junio',
  'Julio',
  'Agosto',
  'Septiembre',
  'Octubre',
  'Noviembre',
  'Diciembre',
];
const _weekdays = ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'];

/// Días festivos o descansos autorizados: en esos días nadie acumula falta.
class HolidaysPage extends StatefulWidget {
  const HolidaysPage({
    super.key,
    required this.store,
    required this.departments,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final HolidayStore store;
  final DepartmentStore departments;
  final DateTime Function() _clock;

  @override
  State<HolidaysPage> createState() => _HolidaysPageState();
}

class _HolidaysPageState extends State<HolidaysPage> {
  late int _year = widget._clock().year;
  List<Holiday> _holidays = [];
  List<Department> _departments = [];
  bool _loading = true;
  bool _busy = false;
  String? _message;
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
      final holidays = await widget.store.list(
        from: DateTime(_year),
        to: DateTime(_year + 1),
      );
      final departments = await widget.departments.list();
      if (mounted) {
        setState(() {
          _holidays = holidays;
          _departments = departments;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudieron cargar los días.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _changeYear(int step) {
    setState(() {
      _year += step;
      _message = null;
    });
    _load();
  }

  Future<void> _run(Future<String?> Function() work) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final message = await work();
      if (mounted) setState(() => _message = message);
      await _load();
    } on HolidayRuleError catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'No se pudo guardar. Vuelve a intentarlo.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addOfficial() => _run(() async {
    final added = await widget.store.addOfficial(_year);
    return added == 0
        ? 'Los festivos oficiales de $_year ya estaban agregados.'
        : 'Se agregaron $added festivos oficiales de $_year.';
  });

  Future<void> _add() async {
    final result =
        await showDialog<({DateTime day, String name, int? departmentId})>(
          context: context,
          builder: (_) => _HolidayDialog(
            year: _year,
            departments: _departments,
            today: widget._clock(),
          ),
        );
    if (result == null) return;
    await _run(() async {
      await widget.store.add(
        day: result.day,
        name: result.name,
        departmentId: result.departmentId,
      );
      return '${result.name} quedó registrado.';
    });
  }

  Future<void> _remove(Holiday holiday) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Quitar este día?'),
        content: Text(
          '${holiday.name} (${holiday.day.day} de ${_months[holiday.day.month - 1].toLowerCase()}) volverá a contar como día laborable y las ausencias de ese día se marcarán como falta.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Quitar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      await widget.store.remove(holiday.id);
      return '${holiday.name} se quitó.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final today = widget._clock();
    final todayDay = DateTime(today.year, today.month, today.day);
    final upcoming = _holidays.where((h) => !h.day.isBefore(todayDay)).toList();
    final byMonth = <int, List<Holiday>>{};
    for (final holiday in _holidays) {
      byMonth.putIfAbsent(holiday.day.month, () => []).add(holiday);
    }
    final body = ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      children: [
        Text(
          'En estos días nadie acumula falta. Si alguien sí trabaja, su checada se registra normal.',
          style: text.bodyMedium?.copyWith(color: AppColors.muted),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Año anterior',
                  onPressed: _busy ? null : () => _changeYear(-1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Text('$_year', style: text.headlineSmall),
                IconButton(
                  tooltip: 'Año siguiente',
                  onPressed: _busy ? null : () => _changeYear(1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy || _loading ? null : _addOfficial,
                  icon: const Icon(Icons.flag_outlined, size: 20),
                  label: Text('Agregar festivos oficiales $_year'),
                ),
                FilledButton.icon(
                  onPressed: _busy || _loading ? null : _add,
                  icon: const Icon(Icons.add, size: 20),
                  label: const Text('Agregar día'),
                ),
              ],
            ),
          ],
        ),
        if (_message != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.infoTint,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 18, color: AppColors.info),
                const SizedBox(width: 10),
                Expanded(child: Text(_message!)),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        if (_loading && _holidays.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Text(_error!, style: const TextStyle(color: AppColors.danger))
        else if (_holidays.isEmpty)
          _EmptyYear(year: _year)
        else ...[
          if (upcoming.isNotEmpty) ...[
            _NextHoliday(holiday: upcoming.first, today: todayDay),
            const SizedBox(height: 20),
          ],
          for (final entry in byMonth.entries) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8, top: 4),
              child: Text(
                _months[entry.key - 1].toUpperCase(),
                style: text.bodySmall?.copyWith(
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(color: AppColors.line),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < entry.value.length; i++) ...[
                    if (i > 0) const Divider(),
                    _HolidayRow(
                      holiday: entry.value[i],
                      past: entry.value[i].day.isBefore(todayDay),
                      onRemove: _busy ? null : () => _remove(entry.value[i]),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ],
      ],
    );
    if (EmbeddedInShell.of(context)) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('Días festivos')),
      body: SafeArea(child: body),
    );
  }
}

class _DateBlock extends StatelessWidget {
  const _DateBlock({required this.day, required this.past});
  final DateTime day;
  final bool past;

  @override
  Widget build(BuildContext context) => Container(
    width: 52,
    padding: const EdgeInsets.symmetric(vertical: 6),
    decoration: BoxDecoration(
      color: past ? AppColors.selected : AppColors.infoTint,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      children: [
        Text(
          '${day.day}',
          style: TextStyle(
            fontSize: 20,
            height: 1.1,
            fontWeight: FontWeight.w700,
            color: past ? AppColors.muted : AppColors.info,
          ),
        ),
        Text(
          _weekdays[day.weekday - 1],
          style: TextStyle(
            fontSize: 12,
            color: past ? AppColors.muted : AppColors.info,
          ),
        ),
      ],
    ),
  );
}

class _HolidayRow extends StatelessWidget {
  const _HolidayRow({required this.holiday, required this.past, this.onRemove});
  final Holiday holiday;
  final bool past;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scope = holiday.departmentName;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          _DateBlock(day: holiday.day, past: past),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  holiday.name,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: past ? AppColors.muted : AppColors.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scope == null
                        ? AppColors.onTimeTint
                        : AppColors.lateTint,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    scope ?? 'Toda la empresa',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scope == null ? AppColors.onTime : AppColors.late,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Quitar',
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline, color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}

class _NextHoliday extends StatelessWidget {
  const _NextHoliday({required this.holiday, required this.today});
  final Holiday holiday;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final days = holiday.day.difference(today).inDays;
    final when = days == 0
        ? 'Hoy'
        : days == 1
        ? 'Mañana'
        : 'En $days días';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.infoTint,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.event_available, color: AppColors.info),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Próximo día de descanso',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  '${holiday.name} · ${holiday.day.day} de ${_months[holiday.day.month - 1].toLowerCase()}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.infoTint,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              when,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.info,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyYear extends StatelessWidget {
  const _EmptyYear({required this.year});
  final int year;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(32),
    decoration: BoxDecoration(
      color: AppColors.surface,
      border: Border.all(color: AppColors.line),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      children: [
        const Icon(Icons.event_busy_outlined, size: 36, color: AppColors.muted),
        const SizedBox(height: 10),
        Text(
          'No hay días registrados en $year.',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          'Usa "Agregar festivos oficiales" para cargar los de la Ley Federal del Trabajo, o agrega un día propio.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}

class _HolidayDialog extends StatefulWidget {
  const _HolidayDialog({
    required this.year,
    required this.departments,
    required this.today,
  });
  final int year;
  final List<Department> departments;
  final DateTime today;

  @override
  State<_HolidayDialog> createState() => _HolidayDialogState();
}

class _HolidayDialogState extends State<_HolidayDialog> {
  final _name = TextEditingController();
  late DateTime _day = widget.today.year == widget.year
      ? DateTime(widget.today.year, widget.today.month, widget.today.day)
      : DateTime(widget.year);
  int? _departmentId;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(widget.year - 1),
      lastDate: DateTime(widget.year + 1, 12, 31),
      locale: const Locale('es', 'MX'),
    );
    if (picked != null) setState(() => _day = picked);
  }

  void _save() {
    final name = _name.text.trim();
    if (name.length < 2) {
      setState(
        () => _error =
            'Escribe el motivo, por ejemplo "Aniversario de la empresa".',
      );
      return;
    }
    Navigator.of(context)
        .pop((day: _day, name: name, departmentId: _departmentId));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Agregar día sin falta'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: _pickDay,
            borderRadius: BorderRadius.circular(6),
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Fecha',
                suffixIcon: Icon(Icons.calendar_today_outlined, size: 20),
              ),
              child: Text(
                '${_weekdays[_day.weekday - 1]} ${_day.day} de ${_months[_day.month - 1].toLowerCase()} de ${_day.year}',
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 80,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Motivo',
              hintText: 'Festivo, puente, aniversario…',
              counterText: '',
              errorText: _error,
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<int?>(
            initialValue: _departmentId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Aplica a'),
            items: [
              const DropdownMenuItem(
                value: null,
                child: Text('Toda la empresa'),
              ),
              for (final d in widget.departments)
                DropdownMenuItem(value: d.id, child: Text('Solo ${d.name}')),
            ],
            onChanged: (value) => setState(() => _departmentId = value),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancelar'),
      ),
      FilledButton(onPressed: _save, child: const Text('Guardar')),
    ],
  );
}
