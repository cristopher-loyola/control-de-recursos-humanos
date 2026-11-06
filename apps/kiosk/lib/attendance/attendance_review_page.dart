import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../admin/admin_shell.dart';
import '../theme/app_theme.dart';

import 'attendance_review_store.dart';

class AttendanceReviewPage extends StatefulWidget {
  const AttendanceReviewPage({super.key, required this.store});

  final AttendanceReviewStore store;

  @override
  State<AttendanceReviewPage> createState() => _AttendanceReviewPageState();
}

class _AttendanceReviewPageState extends State<AttendanceReviewPage> {
  DateTime _day = DateTime.now();
  List<AttendanceReviewItem> _items = [];
  bool _showAll = false;
  bool _loading = true;
  bool _saving = false;
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
      final items = await widget.store.forDay(_day);
      if (mounted) {
        setState(() => _items = items);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No se pudo cargar la revisión de asistencia.');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _selectDay() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (selected == null || !mounted) {
      return;
    }
    setState(() => _day = selected);
    await _load();
  }

  Future<void> _review(
    AttendanceReviewItem item,
    ReviewDecision decision,
  ) async {
    var reasonText = '';
    final form = GlobalKey<FormState>();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${decision.label}: ${item.employeeName}'),
        content: Form(
          key: form,
          child: TextFormField(
            onChanged: (value) => reasonText = value,
            autofocus: true,
            maxLength: 500,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Motivo de la decisión',
              hintText: 'Describe cómo verificaste esta checada',
            ),
            validator: (value) => (value?.trim().length ?? 0) < 10
                ? 'Escribe al menos 10 caracteres.'
                : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.of(dialogContext).pop(reasonText.trim());
              }
            },
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
    if (reason == null || !mounted) {
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.store.review(item.eventId, decision, reason);
      if (mounted) {
        await _load();
      }
    } on ReviewRuleError catch (error) {
      if (mounted) {
        await _load();
        if (mounted) {
          setState(() => _error = error.message);
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No se pudo guardar la revisión.');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  String _reviewedAtLabel(BuildContext context, DateTime date) {
    final local = date.toLocal();
    final day = local.day.toString().padLeft(2, '0');
    final month = local.month.toString().padLeft(2, '0');
    final time = TimeOfDay.fromDateTime(local).format(context);
    return 'Revisada el $day/$month/${local.year} a las $time';
  }

  @override
  Widget build(BuildContext context) {
    final pending = _items.where((item) => item.decision == null).length;
    final approved = _items
        .where((item) => item.decision == ReviewDecision.approved)
        .length;
    final rejected = _items
        .where((item) => item.decision == ReviewDecision.rejected)
        .length;
    final dayLabel =
        '${_day.day.toString().padLeft(2, '0')}/${_day.month.toString().padLeft(2, '0')}/${_day.year}';
    return Scaffold(
      appBar: EmbeddedInShell.of(context)
          ? null
          : AppBar(title: const Text('Revisión de asistencia')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 850),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  'Revisión de checadas',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Llegan aquí los retardos, las salidas anticipadas, las checadas de empleados sin departamento y las manuales. Las que fueron a tiempo se aprueban solas.',
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: _loading || _saving ? null : _selectDay,
                  icon: const Icon(Icons.calendar_today_outlined),
                  label: Text(dayLabel),
                ),
                const SizedBox(height: 16),
                Text(
                  'Pendientes: $pending  ·  Aprobadas: $approved  ·  Rechazadas: $rejected',
                ),
                const SizedBox(height: 16),
                if (_loading || _saving) const LinearProgressIndicator(),
                if (_error != null) ...[
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  TextButton(
                    onPressed: _load,
                    child: const Text('Volver a intentar'),
                  ),
                ],
                if (!_loading && _items.isEmpty)
                  const Text('No hay checadas en este día.')
                else if (!_loading && pending == 0 && !_showAll)
                  const Text('No hay checadas por revisar en este día.'),
                if (_items.length > pending)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setState(() => _showAll = !_showAll),
                      child: Text(
                        _showAll
                            ? 'Mostrar solo las pendientes'
                            : 'Ver también las ya resueltas (${_items.length - pending})',
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                for (final item in _items.where(
                  (item) => _showAll || item.decision == null,
                ))
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${item.kind == 'entry' ? 'Entrada' : 'Salida'} · ${item.employeeName}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'N.º ${item.employeeNumber} · ${TimeOfDay.fromDateTime(item.occurredAt.toLocal()).format(context)}',
                          ),
                          if (item.scheduleNote != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              item.scheduleNote!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          Text(item.decision?.label ?? 'Pendiente de revisión'),
                          Text(switch (item.captureMethod) {
                            'facial' =>
                              'Identificación facial · sin prueba de vida',
                            'pin' => 'PIN del empleado · confirma su identidad con la foto',
                            _ => 'Registro manual · identidad sin verificar',
                          }),
                          if (item.hasPhoto) ...[
                            const SizedBox(height: 12),
                            _PhotoThumb(
                              load: () => widget.store.photo(item.eventId),
                              title:
                                  '${item.employeeName} · ${TimeOfDay.fromDateTime(item.occurredAt.toLocal()).format(context)}',
                            ),
                          ],
                          if (item.reason != null) ...[
                            const SizedBox(height: 4),
                            Text('Motivo: ${item.reason} · ${item.reviewer}'),
                          ],
                          if (item.reviewedAt != null) ...[
                            const SizedBox(height: 4),
                            Text(_reviewedAtLabel(context, item.reviewedAt!)),
                          ],
                          if (item.decision == null) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              children: [
                                FilledButton(
                                  onPressed: _loading || _saving
                                      ? null
                                      : () => _review(
                                          item,
                                          ReviewDecision.approved,
                                        ),
                                  child: const Text('Aprobar'),
                                ),
                                OutlinedButton(
                                  onPressed: _loading || _saving
                                      ? null
                                      : () => _review(
                                          item,
                                          ReviewDecision.rejected,
                                        ),
                                  child: const Text('Rechazar'),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Como espejo, igual que la vista de la cámara frontal en el checador. La
/// foto guardada no se altera.
Widget _mirrored(Widget image) => Transform.flip(flipX: true, child: image);

/// Foto tomada en el checador al usar PIN. Se descifra solo al mostrarla.
class _PhotoThumb extends StatefulWidget {
  const _PhotoThumb({required this.load, required this.title});
  final Future<Uint8List?> Function() load;
  final String title;

  @override
  State<_PhotoThumb> createState() => _PhotoThumbState();
}

class _PhotoThumbState extends State<_PhotoThumb> {
  late final Future<Uint8List?> _photo = widget.load();

  void _open(Uint8List bytes) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: _mirrored(Image.memory(bytes, fit: BoxFit.contain)),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _photo,
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      final Widget child;
      if (snapshot.connectionState != ConnectionState.done) {
        child = const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      } else if (bytes == null) {
        child = const Center(
          child: Text('Foto no disponible', textAlign: TextAlign.center),
        );
      } else {
        child = _mirrored(Image.memory(bytes, fit: BoxFit.cover));
      }
      return Tooltip(
        message: 'Ver foto',
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: bytes == null ? null : () => _open(bytes),
          child: Container(
            width: 120,
            height: 120,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.line),
            ),
            child: child,
          ),
        ),
      );
    },
  );
}
