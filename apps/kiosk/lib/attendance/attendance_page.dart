import 'package:flutter/material.dart';

import '../admin/admin_shell.dart';

import 'dart:async';

import '../employees/employee_store.dart';
import 'attendance_store.dart';

class AttendancePage extends StatefulWidget {
  const AttendancePage({
    super.key,
    required this.employees,
    required this.attendance,
    this.publicMode = false,
    this.onOpenAdmin,
  });
  final EmployeeStore employees;
  final AttendanceStore attendance;
  final bool publicMode;
  final VoidCallback? onOpenAdmin;

  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage> {
  List<Employee> _employees = [];
  List<AttendanceEvent> _events = [];
  AttendanceEvent? _last;
  String? _selected;
  String? _error;
  String? _message;
  bool _loading = true;
  bool _saving = false;
  DateTime _day = DateTime.now();
  Timer? _dayTimer;

  @override
  void initState() {
    super.initState();
    if (widget.publicMode) {
      _loading = false;
      return;
    }
    _load();
    _dayTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final now = DateTime.now();
      if (!_loading &&
          !_saving &&
          (now.year != _day.year ||
              now.month != _day.month ||
              now.day != _day.day)) {
        _load();
      }
    });
  }

  Future<void> _load() async {
    if (widget.publicMode) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final day = DateTime.now();
      final employees = await widget.employees.list();
      final selected = employees.any((e) => e.number == _selected)
          ? _selected
          : (employees.isEmpty ? null : employees.first.number);
      final events = await widget.attendance.forDay(day);
      final last = selected == null
          ? null
          : await widget.attendance.lastFor(selected);
      if (!mounted) {
        return;
      }
      setState(() {
        _day = day;
        _employees = employees;
        _selected = selected;
        _events = events;
        _last = last;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'No se pudo consultar la asistencia. Vuelve a intentarlo.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _select(String? number) async {
    if (number == null) {
      return;
    }
    setState(() {
      _selected = number;
      _message = null;
    });
    await _load();
  }

  Future<void> _record(AttendanceKind kind) async {
    if (widget.publicMode) return;
    final number = _selected;
    if (number == null || _saving || _loading || _error != null) {
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await widget.attendance.record(number, kind);
      if (!mounted) {
        return;
      }
      setState(
        () =>
            _message = '${kind.label} guardada; pendiente de revisión por RH.',
      );
      await _load();
    } on AttendanceRuleError catch (error) {
      if (mounted) {
        setState(() => _message = error.message);
      }
      if (mounted) {
        await _load();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'No se pudo registrar el movimiento. Vuelve a intentarlo.',
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
    _dayTimer?.cancel();
    super.dispose();
  }

  String _date(DateTime date) {
    final local = date.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}/${local.year}';
  }

  String _time(DateTime date) {
    final local = date.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.publicMode) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Entradas y salidas'),
          actions: [
            if (widget.onOpenAdmin != null)
              TextButton.icon(
                onPressed: widget.onOpenAdmin,
                icon: const Icon(Icons.admin_panel_settings_outlined),
                label: const Text('Administrar'),
              ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Checador',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'La checada facial todavía está en desarrollo. Si necesitas registrar una entrada o salida, solicita apoyo a RH o al administrador.',
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'El personal autorizado puede registrar una checada manual y dejarla pendiente de revisión.',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    final busy = _loading || _saving;
    final nextKind = _last?.kind == AttendanceKind.entry
        ? AttendanceKind.exit
        : AttendanceKind.entry;
    final alreadyRecorded = _events.any(
      (event) => event.employeeNumber == _selected && event.kind == nextKind,
    );
    final canRecord =
        !busy && _error == null && _selected != null && !alreadyRecorded;
    final hasEntry = _last?.kind == AttendanceKind.entry;
    return Scaffold(
      appBar: EmbeddedInShell.of(context)
          ? null
          : AppBar(
              title: const Text('Entradas y salidas'),
              actions: [
                if (widget.onOpenAdmin != null)
                  TextButton.icon(
                    onPressed: busy ? null : widget.onOpenAdmin,
                    icon: const Icon(Icons.admin_panel_settings_outlined),
                    label: const Text('Administrar'),
                  ),
                IconButton(
                  onPressed: busy ? null : _load,
                  tooltip: 'Actualizar',
                  icon: const Icon(Icons.refresh),
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
                const Text(
                  'Selecciona al empleado y registra su movimiento manual.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'La identidad no se verifica aquí. Cada movimiento queda pendiente de revisión por RH.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'Una entrada y una salida por empleado al día. Se utiliza la fecha y hora de esta tablet.',
                ),
                const SizedBox(height: 24),
                if (_loading) const LinearProgressIndicator(),
                if (_error != null) ...[
                  Text(_error!),
                  TextButton(
                    onPressed: busy ? null : _load,
                    child: const Text('Volver a intentar'),
                  ),
                ] else if (!_loading && _employees.isEmpty)
                  const Text(
                    'Primero registra un empleado en la pantalla anterior.',
                  )
                else if (_employees.isNotEmpty) ...[
                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Empleado',
                      border: OutlineInputBorder(),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _selected,
                        isExpanded: true,
                        items: _employees
                            .map(
                              (employee) => DropdownMenuItem(
                                value: employee.number,
                                child: Text(
                                  '${employee.number} · ${employee.name}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: busy ? null : _select,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    hasEntry
                        ? 'Tiene una entrada abierta.'
                        : 'Sin entrada abierta.',
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: canRecord && !hasEntry
                            ? () => _record(AttendanceKind.entry)
                            : null,
                        icon: const Icon(Icons.login),
                        label: const Text('Registrar entrada'),
                      ),
                      FilledButton.icon(
                        onPressed: canRecord && hasEntry
                            ? () => _record(AttendanceKind.exit)
                            : null,
                        icon: const Icon(Icons.logout),
                        label: const Text('Registrar salida'),
                      ),
                    ],
                  ),
                ],
                if (alreadyRecorded && !_loading && _error == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Ya se registró el movimiento permitido para hoy.',
                    ),
                  ),
                if (_saving)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Guardando…'),
                  ),
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Semantics(liveRegion: true, child: Text(_message!)),
                  ),
                if (widget.onOpenAdmin == null) ...[
                  const Divider(height: 40),
                  Text(
                    'Historial · ${_day.day}/${_day.month}/${_day.year}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  if (!busy && _error == null && _events.isEmpty)
                    const Text('Aún no hay movimientos hoy.'),
                  for (final event in _events)
                    Card(
                      child: ListTile(
                        leading: Icon(
                          event.kind == AttendanceKind.entry
                              ? Icons.login
                              : Icons.logout,
                        ),
                        title: Text(
                          '${event.kind.label} · ${event.employeeName}',
                        ),
                        subtitle: Text(
                          'Número: ${event.employeeNumber} · ${_date(event.occurredAt)} · ${_time(event.occurredAt)}',
                        ),
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
}
