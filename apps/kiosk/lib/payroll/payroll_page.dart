import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../admin/admin_shell.dart';
import '../admin/dashboard_widgets.dart';
import '../reports/file_share.dart';
import '../theme/app_theme.dart';
import 'payroll.dart';
import 'payroll_export.dart';
import 'payroll_store.dart';

const _months = [
  'enero',
  'febrero',
  'marzo',
  'abril',
  'mayo',
  'junio',
  'julio',
  'agosto',
  'septiembre',
  'octubre',
  'noviembre',
  'diciembre',
];
const _weekdays = [
  'lunes',
  'martes',
  'miércoles',
  'jueves',
  'viernes',
  'sábado',
  'domingo',
];
const Tone _ink = (strong: AppColors.ink, tint: AppColors.selected);

String _periodLabel(DateTime start, DateTime last) {
  if (start.day == 1 &&
      DateTime(last.year, last.month, last.day + 1).month != last.month) {
    final month = _months[start.month - 1];
    return '${month[0].toUpperCase()}${month.substring(1)} ${start.year}';
  }
  return start.month == last.month
      ? '${start.day} al ${last.day} de ${_months[last.month - 1]}'
      : '${start.day} de ${_months[start.month - 1]} al ${last.day} de ${_months[last.month - 1]}';
}

String _shortDate(DateTime d) => '${d.day} de ${_months[d.month - 1]}';

/// Pre-nómina del periodo: lo que corresponde a cada empleado según su
/// salario diario, las faltas y los retardos. Se cierra para congelarla.
class PayrollPage extends StatefulWidget {
  const PayrollPage({
    super.key,
    required this.store,
    this.canReopen = false,
    this.organizationName,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final PayrollStore store;
  final bool canReopen;
  final String? organizationName;
  final DateTime Function() _clock;

  @override
  State<PayrollPage> createState() => _PayrollPageState();
}

class _PayrollPageState extends State<PayrollPage> {
  late DateTime _anchor = widget._clock();
  PayrollData? _data;
  bool _loading = true;
  bool _busy = false;
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
      final data = await widget.store.load(_anchor);
      if (mounted) setState(() => _data = data);
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudo cargar la pre-nómina.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _step(int step) {
    final data = _data;
    if (data == null) return;
    setState(() => _anchor = shiftPayPeriod(data.policy, _anchor, step));
    _load();
  }

  void _notify(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _editPolicy() async {
    final data = _data;
    if (data == null) return;
    final current = await widget.store.policy();
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _PolicyDialog(store: widget.store, policy: current),
    );
    if (saved == true) {
      _anchor = widget._clock();
      await _load();
      if (mounted) _notify('Reglas guardadas.');
    }
  }

  Future<void> _close() async {
    final data = _data;
    if (data == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cerrar periodo'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Se congelan los montos del ${_shortDate(data.start)} al ${_shortDate(data.lastDay)}. Después solo el administrador puede reabrirlo, con un motivo.',
              ),
              if (data.withoutWage > 0 || data.incomplete > 0) ...[
                const SizedBox(height: 12),
                if (data.withoutWage > 0)
                  Text(
                    '· ${data.withoutWage} con salario sin capturar: su total queda vacío.',
                  ),
                if (data.incomplete > 0)
                  Text(
                    '· ${data.incomplete} jornadas sin salida: no se descuentan.',
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cerrar periodo'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() => widget.store.close(_anchor), 'Periodo cerrado.');
  }

  Future<void> _reopen() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _ReopenDialog(),
    );
    if (reason == null) return;
    await _run(
      () => widget.store.reopen(_anchor, reason),
      'Periodo reabierto. Los montos se vuelven a calcular.',
    );
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
      if (mounted) _notify(done);
    } on PayrollRuleError catch (error) {
      if (mounted) _notify(error.message);
    } catch (_) {
      if (mounted) _notify('No se pudo completar. Vuelve a intentarlo.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Guarda el Excel en la tablet o, con [share], abre el menú para enviarlo.
  Future<void> _export({bool share = false}) async {
    final data = _data;
    if (data == null) return;
    setState(() => _busy = true);
    try {
      final start = data.start;
      final name =
          'prenomina-${start.year}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}.xlsx';
      final bytes = buildPayrollWorkbook(
        data: data,
        generatedAt: widget._clock(),
        organizationName: widget.organizationName,
      );
      if (share) {
        await shareFile(
          name: name,
          bytes: bytes,
          title: 'Compartir pre-nómina',
        );
        return;
      }
      final saved = await FilePicker.saveFile(
        fileName: name,
        bytes: bytes,
        mimeType: xlsxMimeType,
        dialogTitle: 'Guardar pre-nómina',
      );
      if (mounted) {
        _notify(
          saved == null ? 'Exportación cancelada.' : 'Pre-nómina guardada.',
        );
      }
    } catch (_) {
      if (mounted) {
        _notify(
          share
              ? 'No se pudo compartir el archivo.'
              : 'No se pudo generar el archivo de Excel.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final body = RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        children: [
          if (data != null) _toolbar(context, data),
          const SizedBox(height: 16),
          if (_error != null)
            Center(child: Text(_error!))
          else if (data == null)
            const Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            AnimatedOpacity(
              opacity: _loading ? 0.45 : 1,
              duration: const Duration(milliseconds: 180),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ..._alerts(context, data),
                  _totals(data),
                  const SizedBox(height: 20),
                  _table(context, data),
                  const SizedBox(height: 12),
                  Text(
                    'Montos antes de impuestos, IMSS y otras percepciones o deducciones. Las jornadas sin salida se marcan pero no se descuentan.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (EmbeddedInShell.of(context)) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('Pre-nómina')),
      body: SafeArea(child: body),
    );
  }

  Widget _toolbar(BuildContext context, PayrollData data) {
    final text = Theme.of(context).textTheme;
    final atPresent = data.end.isAfter(widget._clock());
    final (Tone tone, IconData icon, String status) = data.closed
        ? (toneOnTime, Icons.lock_outline, 'Cerrado')
        : data.ended
        ? (toneLate, Icons.pending_actions_outlined, 'Por cerrar')
        : (toneNeutral, Icons.timelapse, 'En curso');
    final navigation = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        RoundIcon(
          icon: Icons.chevron_left,
          tooltip: 'Periodo anterior',
          onTap: _loading ? null : () => _step(-1),
        ),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 200),
          child: Column(
            children: [
              Text(
                _periodLabel(data.start, data.lastDay),
                textAlign: TextAlign.center,
                style: text.titleMedium,
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
                decoration: BoxDecoration(
                  color: tone.tint,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 14, color: tone.strong),
                    const SizedBox(width: 4),
                    Text(
                      '$status · ${data.policy.kind.label.toLowerCase()}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: tone.strong,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        RoundIcon(
          icon: Icons.chevron_right,
          tooltip: 'Periodo siguiente',
          onTap: _loading || atPresent ? null : () => _step(1),
        ),
      ],
    );
    final Widget primary;
    if (data.closed) {
      primary = widget.canReopen
          ? OutlinedButton.icon(
              onPressed: _busy ? null : _reopen,
              icon: const Icon(Icons.lock_open_outlined, size: 20),
              label: const Text('Reabrir'),
            )
          : const SizedBox.shrink();
    } else {
      primary = Tooltip(
        message: !data.ended
            ? 'Se puede cerrar al terminar el periodo'
            : data.pendingReviews > 0
            ? 'Primero revisa las checadas pendientes'
            : '',
        child: FilledButton.icon(
          onPressed: _busy || !data.ended || data.pendingReviews > 0
              ? null
              : _close,
          icon: const Icon(Icons.lock_outline, size: 20),
          label: const Text('Cerrar periodo'),
        ),
      );
    }
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      children: [
        navigation,
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _editPolicy,
              icon: const Icon(Icons.tune, size: 20),
              label: const Text('Reglas'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _export,
              icon: const Icon(Icons.file_download_outlined, size: 20),
              label: const Text('Excel'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _export(share: true),
              icon: const Icon(Icons.share_outlined, size: 20),
              label: const Text('Compartir'),
            ),
            primary,
          ],
        ),
      ],
    );
  }

  List<Widget> _alerts(BuildContext context, PayrollData data) {
    final shell = AdminShell.maybeOf(context);
    Widget alert(Tone tone, IconData icon, String text, [Widget? action]) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: EdgeInsets.fromLTRB(16, 8, action == null ? 16 : 8, 8),
            decoration: BoxDecoration(
              color: tone.tint,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(icon, size: 20, color: tone.strong),
                const SizedBox(width: 12),
                Expanded(child: Text(text)),
                ?action,
              ],
            ),
          ),
        );
    final closure = data.closure;
    return [
      if (closure != null)
        alert(
          toneOnTime,
          Icons.lock_outline,
          'Cerrado el ${_shortDate(closure.closedAt.toLocal())} por ${closure.actor}. Los montos ya no cambian${widget.canReopen ? '' : '; solo el administrador puede reabrirlo'}.',
        ),
      if (!data.closed && data.pendingReviews > 0)
        alert(
          toneInfo,
          Icons.fact_check_outlined,
          data.pendingReviews == 1
              ? '1 checada por revisar. Debe resolverse antes de cerrar.'
              : '${data.pendingReviews} checadas por revisar. Deben resolverse antes de cerrar.',
          TextButton(
            onPressed: () => shell?.show('Asistencia'),
            child: const Text('Revisar'),
          ),
        ),
      if (data.withoutWage > 0)
        alert(
          toneInfo,
          Icons.payments_outlined,
          data.withoutWage == 1
              ? '1 empleado no tiene salario diario. Captúralo en su departamento o en su ficha.'
              : '${data.withoutWage} empleados no tienen salario diario. Captúralo en su departamento o en su ficha.',
          TextButton(
            onPressed: () => shell?.show('Departamentos'),
            child: const Text('Departamentos'),
          ),
        ),
      if (data.incomplete > 0)
        alert(
          toneLate,
          Icons.logout,
          data.incomplete == 1
              ? '1 jornada sin salida registrada. Aclárala con el empleado.'
              : '${data.incomplete} jornadas sin salida registrada. Aclara cada una con el empleado.',
        ),
    ];
  }

  Widget _totals(PayrollData data) {
    final paid = data.lines.where((l) => l.gross != null).toList();
    int sum(int Function(PayrollLine) value) =>
        paid.fold(0, (total, l) => total + value(l));
    final gross = sum((l) => l.gross!);
    final deduction = sum((l) => l.deduction!);
    final absences = data.lines.fold(0, (t, l) => t + l.absences);
    final lates = data.lines.fold(0, (t, l) => t + l.lates);
    final latesAsAbsences = data.lines.fold(0, (t, l) => t + l.latesAsAbsences);
    final policy = data.policy;
    final cards = [
      KpiCard(
        tone: _ink,
        icon: Icons.payments_outlined,
        label: 'Total a pagar',
        value: formatMoney(gross - deduction),
        caption: '${paid.length} empleados · base ${formatMoney(gross)}',
      ),
      KpiCard(
        tone: toneAbsent,
        icon: Icons.remove_circle_outline,
        label: 'Descuentos',
        value: deduction == 0 ? '0' : formatMoney(deduction),
        caption: 'falta = ${formatDays(policy.absenceDays)} días de salario',
      ),
      KpiCard(
        tone: toneAbsent,
        icon: Icons.person_off_outlined,
        label: 'Faltas',
        value: '$absences',
        caption: latesAsAbsences == 0
            ? null
            : '+ $latesAsAbsences por retardos',
      ),
      KpiCard(
        tone: toneLate,
        icon: Icons.schedule,
        label: 'Retardos',
        value: '$lates',
        caption: policy.latesPerAbsence == 0
            ? 'No descuentan'
            : '${policy.latesPerAbsence} retardos = 1 falta',
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final perRow = constraints.maxWidth >= 900 ? 4 : 2;
        final width = (constraints.maxWidth - 12 * (perRow - 1)) / perRow;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final card in cards) SizedBox(width: width, child: card),
          ],
        );
      },
    );
  }

  Widget _table(BuildContext context, PayrollData data) {
    final text = Theme.of(context).textTheme;
    final header = text.bodySmall?.copyWith(fontWeight: FontWeight.w600);
    const tabular = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);
    final rows = [...data.lines]
      ..sort((a, b) {
        final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        if (a.hasSchedule != b.hasSchedule) return a.hasSchedule ? -1 : 1;
        return byName;
      });
    return Panel(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 760;
          Widget cell(double width, Widget child) => SizedBox(
            width: width,
            child: Align(alignment: Alignment.centerRight, child: child),
          );
          Widget headerCell(double width, String label) => cell(
            width,
            Text(label, textAlign: TextAlign.right, style: header),
          );
          return Column(
            children: [
              Container(
                color: AppColors.background,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Expanded(child: Text('Empleado', style: header)),
                    if (wide) ...[
                      headerCell(112, 'Salario diario'),
                      headerCell(64, 'Días'),
                    ],
                    headerCell(64, 'Faltas'),
                    headerCell(80, 'Retardos'),
                    headerCell(112, 'Descuento'),
                    headerCell(124, 'Total'),
                  ],
                ),
              ),
              const Divider(),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text('Aún no hay empleados.', style: text.bodySmall),
                ),
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const Divider(),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: PersonIdentity(
                          name: rows[i].name,
                          department: rows[i].incomplete > 0
                              ? '${rows[i].departmentName ?? 'Sin departamento'} · ${rows[i].incomplete} sin salida'
                              : rows[i].departmentName ?? 'Sin departamento',
                          tone:
                              !rows[i].hasSchedule || rows[i].dailyWage == null
                              ? toneInfo
                              : rows[i].absences > 0
                              ? toneAbsent
                              : rows[i].lates > 0
                              ? toneLate
                              : toneOnTime,
                        ),
                      ),
                      if (!rows[i].hasSchedule)
                        Text('Sin horario asignado', style: text.bodySmall)
                      else if (rows[i].dailyWage == null) ...[
                        if (wide) ...[
                          cell(112, const Text('—')),
                          cell(64, const Text('—')),
                        ],
                        cell(
                          64,
                          rows[i].absences == 0
                              ? const Text('0', style: tabular)
                              : StatusBadge(
                                  text: '${rows[i].absences}',
                                  tone: toneAbsent,
                                ),
                        ),
                        cell(80, Text('${rows[i].lates}', style: tabular)),
                        cell(
                          236,
                          const StatusBadge(
                            text: 'Sin salario',
                            tone: toneInfo,
                          ),
                        ),
                      ] else ...[
                        if (wide) ...[
                          cell(
                            112,
                            Text(
                              formatMoney(rows[i].dailyWage!),
                              style: tabular.copyWith(
                                color: rows[i].ownWage
                                    ? AppColors.ink
                                    : AppColors.muted,
                              ),
                            ),
                          ),
                          cell(
                            64,
                            Text(formatDays(rows[i].paidDays), style: tabular),
                          ),
                        ],
                        cell(
                          64,
                          rows[i].absences == 0
                              ? const Text('0', style: tabular)
                              : StatusBadge(
                                  text: '${rows[i].absences}',
                                  tone: toneAbsent,
                                ),
                        ),
                        cell(
                          80,
                          rows[i].lates == 0
                              ? const Text('0', style: tabular)
                              : StatusBadge(
                                  text: rows[i].latesAsAbsences == 0
                                      ? '${rows[i].lates}'
                                      : '${rows[i].lates} → ${rows[i].latesAsAbsences}F',
                                  tone: toneLate,
                                ),
                        ),
                        cell(
                          112,
                          Text(
                            rows[i].deduction == 0
                                ? '—'
                                : '-${formatMoney(rows[i].deduction!)}',
                            style: tabular.copyWith(
                              color: rows[i].deduction == 0
                                  ? AppColors.muted
                                  : AppColors.absent,
                            ),
                          ),
                        ),
                        cell(
                          124,
                          Text(
                            formatMoney(rows[i].total!),
                            style: tabular.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _PolicyDialog extends StatefulWidget {
  const _PolicyDialog({required this.store, required this.policy});
  final PayrollStore store;
  final PayrollPolicy policy;

  @override
  State<_PolicyDialog> createState() => _PolicyDialogState();
}

class _PolicyDialogState extends State<_PolicyDialog> {
  late PayPeriodKind _kind = widget.policy.kind;
  late int _weekStart = widget.policy.weekStart;
  late final _paidDays = TextEditingController(
    text: formatDays(widget.policy.paidDays),
  );
  late final _absenceDays = TextEditingController(
    text: formatDays(widget.policy.absenceDays),
  );
  late final _lates = TextEditingController(
    text: '${widget.policy.latesPerAbsence}',
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _paidDays.dispose();
    _absenceDays.dispose();
    _lates.dispose();
    super.dispose();
  }

  void _setKind(PayPeriodKind kind) {
    setState(() {
      _kind = kind;
      _paidDays.text = formatDays(kind.defaultPaidDays);
    });
  }

  Future<void> _save() async {
    final paid = double.tryParse(_paidDays.text.trim());
    final absence = double.tryParse(_absenceDays.text.trim());
    final lates = int.tryParse(_lates.text.trim());
    if (paid == null || absence == null || lates == null) {
      setState(() => _error = 'Revisa que los tres valores sean números.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.savePolicy(
        PayrollPolicy(
          kind: _kind,
          weekStart: _weekStart,
          paidDays: paid,
          absenceDays: absence,
          latesPerAbsence: lates,
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on PayrollRuleError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudo guardar.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final decimal = [
      FilteringTextInputFormatter.allow(RegExp(r'^\d{0,2}(\.\d{0,2})?')),
    ];
    return AlertDialog(
      title: const Text('Reglas de pre-nómina'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Periodo de pago', style: text.bodySmall),
              const SizedBox(height: 8),
              SegmentedButton<PayPeriodKind>(
                showSelectedIcon: false,
                segments: [
                  for (final kind in PayPeriodKind.values)
                    ButtonSegment(value: kind, label: Text(kind.label)),
                ],
                selected: {_kind},
                onSelectionChanged: _saving
                    ? null
                    : (value) => _setKind(value.single),
              ),
              if (_kind == PayPeriodKind.weekly) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  initialValue: _weekStart,
                  decoration: const InputDecoration(
                    labelText: 'La semana empieza el',
                  ),
                  items: [
                    for (var day = 1; day <= 7; day++)
                      DropdownMenuItem(
                        value: day,
                        child: Text(_weekdays[day - 1]),
                      ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _weekStart = value ?? 1),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _paidDays,
                enabled: !_saving,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: decimal,
                decoration: const InputDecoration(
                  labelText: 'Días de salario que se pagan por periodo',
                  helperText: 'Incluye descansos y festivos pagados.',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _absenceDays,
                enabled: !_saving,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: decimal,
                decoration: const InputDecoration(
                  labelText: 'Cada falta descuenta (días de salario)',
                  helperText: 'Ej. 1, o 1.17 si también se descuenta la parte del descanso.',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _lates,
                enabled: !_saving,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Retardos que equivalen a una falta',
                  helperText: '0 = los retardos no descuentan. Debe estar en el reglamento interior de trabajo.',
                  helperMaxLines: 2,
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
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

class _ReopenDialog extends StatefulWidget {
  const _ReopenDialog();

  @override
  State<_ReopenDialog> createState() => _ReopenDialogState();
}

class _ReopenDialogState extends State<_ReopenDialog> {
  final _reason = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reason.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = _reason.text.trim().length >= 10;
    return AlertDialog(
      title: const Text('Reabrir periodo'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Los montos se vuelven a calcular con los datos actuales. El motivo queda en el historial.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _reason,
              autofocus: true,
              maxLength: 500,
              maxLines: 3,
              minLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Motivo',
                hintText: 'Ej. Se justificó la falta del 3 de noviembre.',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: valid
              ? () => Navigator.of(context).pop(_reason.text.trim())
              : null,
          child: const Text('Reabrir'),
        ),
      ],
    );
  }
}
