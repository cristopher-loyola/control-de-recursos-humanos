import 'package:flutter/material.dart';

import '../departments/schedule.dart';
import '../reports/attendance_report.dart';
import '../reports/report_store.dart';
import '../theme/app_theme.dart';
import 'admin_shell.dart';

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

String _time(DateTime value) {
  final local = value.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

String _capitalize(String text) =>
    text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';

/// Colores de un estado de asistencia: fuerte para el dato, tinte para el fondo.
typedef _Tone = ({Color strong, Color tint});
const _Tone _onTime = (strong: AppColors.onTime, tint: AppColors.onTimeTint);
const _Tone _late = (strong: AppColors.late, tint: AppColors.lateTint);
const _Tone _absent = (strong: AppColors.absent, tint: AppColors.absentTint);
const _Tone _info = (strong: AppColors.info, tint: AppColors.infoTint);
const _Tone _neutral = (strong: AppColors.muted, tint: AppColors.selected);

/// Tablero de asistencia por día, semana o mes, con filtro por departamento.
class HomeSection extends StatefulWidget {
  const HomeSection({
    super.key,
    required this.reports,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final ReportStore reports;
  final DateTime Function() _clock;

  @override
  State<HomeSection> createState() => _HomeSectionState();
}

class _HomeSectionState extends State<HomeSection> {
  ReportPeriod _period = ReportPeriod.day;
  late DateTime _anchor = widget._clock();

  /// null = todos; -1 = sin departamento.
  int? _department;
  ReportData? _data;
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
    final range = periodRange(_period, _anchor);
    try {
      final data = await widget.reports.load(
        start: range.start,
        end: range.end,
        departmentId: _department == -1 ? null : _department,
        withoutDepartment: _department == -1,
      );
      if (mounted) setState(() => _data = data);
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudo cargar la asistencia.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setPeriod(ReportPeriod period) {
    setState(() => _period = period);
    _load();
  }

  void _step(int step) {
    setState(() => _anchor = shiftPeriod(_period, _anchor, step));
    _load();
  }

  void _setDepartment(int? department) {
    setState(() => _department = department);
    _load();
  }

  String get _label {
    final now = widget._clock();
    final range = periodRange(_period, _anchor);
    switch (_period) {
      case ReportPeriod.day:
        final today = DateTime(now.year, now.month, now.day);
        final prefix = range.start == today
            ? 'Hoy'
            : _capitalize(_weekdays[range.start.weekday - 1]);
        return '$prefix, ${range.start.day} de ${_months[range.start.month - 1]}';
      case ReportPeriod.week:
        final last = DateTime(
          range.end.year,
          range.end.month,
          range.end.day - 1,
        );
        return last.month == range.start.month
            ? '${range.start.day} al ${last.day} de ${_months[last.month - 1]}'
            : '${range.start.day} de ${_months[range.start.month - 1]} al ${last.day} de ${_months[last.month - 1]}';
      case ReportPeriod.month:
        return '${_capitalize(_months[range.start.month - 1])} ${range.start.year}';
    }
  }

  bool get _atPresent =>
      !periodRange(_period, _anchor).end.isBefore(widget._clock());

  String get _departmentLabel {
    if (_department == null) return 'Todos los departamentos';
    if (_department == -1) return 'Sin departamento';
    for (final d in _data?.departments ?? const <({int id, String name})>[]) {
      if (d.id == _department) return d.name;
    }
    return 'Departamento';
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        children: [
          _toolbar(context),
          const SizedBox(height: 20),
          if (_error != null)
            _Empty(icon: Icons.error_outline, text: _error!)
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
                  if (data.holidays.isNotEmpty) ...[
                    _holidayBanner(context, data.holidays),
                    const SizedBox(height: 12),
                  ],
                  _totals(context, data),
                  const SizedBox(height: 20),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: _period == ReportPeriod.day
                        ? KeyedSubtree(
                            key: const ValueKey('day'),
                            child: _dayLists(context, data),
                          )
                        : KeyedSubtree(
                            key: ValueKey(_period),
                            child: _concentrate(context, data),
                          ),
                  ),
                  if (data.withoutFace > 0) ...[
                    const SizedBox(height: 16),
                    _notice(context, data.withoutFace),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final periods = Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.selected,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (period, label) in const [
            (ReportPeriod.day, 'Día'),
            (ReportPeriod.week, 'Semana'),
            (ReportPeriod.month, 'Mes'),
          ])
            _PeriodTab(
              label: label,
              selected: _period == period,
              onTap: () => _setPeriod(period),
            ),
        ],
      ),
    );
    final navigation = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RoundIcon(
          icon: Icons.chevron_left,
          tooltip: 'Anterior',
          onTap: () => _step(-1),
        ),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 180),
          child: Text(
            _label,
            textAlign: TextAlign.center,
            style: text.titleMedium,
          ),
        ),
        const SizedBox(width: 8),
        _RoundIcon(
          icon: Icons.chevron_right,
          tooltip: 'Siguiente',
          onTap: _atPresent ? null : () => _step(1),
        ),
      ],
    );
    final departments = _data?.departments ?? const <({int id, String name})>[];
    final filter = PopupMenuButton<int?>(
      tooltip: 'Filtrar por departamento',
      position: PopupMenuPosition.under,
      onSelected: _setDepartment,
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: null,
          child: Text('Todos los departamentos'),
        ),
        for (final d in departments)
          PopupMenuItem(value: d.id, child: Text(d.name)),
        const PopupMenuItem(value: -1, child: Text('Sin departamento')),
      ],
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: _department == null ? AppColors.surface : AppColors.infoTint,
          border: Border.all(
            color: _department == null ? AppColors.line : AppColors.info,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.filter_list,
              size: 18,
              color: _department == null ? AppColors.muted : AppColors.info,
            ),
            const SizedBox(width: 8),
            Text(
              _departmentLabel,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: _department == null ? AppColors.ink : AppColors.info,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 20, color: AppColors.muted),
          ],
        ),
      ),
    );
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      children: [periods, navigation, filter],
    );
  }

  Widget _totals(BuildContext context, ReportData data) {
    final scheduled = data.summaries.where((s) => s.hasSchedule).toList();
    int sum(int Function(EmployeeSummary) value) =>
        scheduled.fold(0, (total, s) => total + value(s));
    final workDays = sum((s) => s.workDays);
    final attended = sum((s) => s.attended);
    final rate = workDays == 0 ? null : attended / workDays;
    final shell = AdminShell.maybeOf(context);
    final isDay = _period == ReportPeriod.day;
    final cards = [
      _KpiCard(
        tone: _onTime,
        icon: Icons.check_circle_outline,
        label: 'A tiempo',
        value: '${sum((s) => s.onTime)}',
      ),
      _KpiCard(
        tone: _late,
        icon: Icons.schedule,
        label: 'Retardos',
        value: '${sum((s) => s.late)}',
        caption: sum((s) => s.lateMinutes) == 0
            ? null
            : '${formatDuration(sum((s) => s.lateMinutes))} en total',
      ),
      _KpiCard(
        tone: _absent,
        icon: Icons.person_off_outlined,
        label: isDay ? 'No llegaron' : 'Faltas',
        value: '${sum((s) => s.absent)}',
      ),
      _KpiCard(
        tone: _neutral,
        icon: Icons.insights_outlined,
        label: 'Asistencia',
        value: rate == null ? '—' : '${(rate * 100).round()}%',
        progress: rate,
        caption: workDays == 0 ? null : '$attended de $workDays',
      ),
      _KpiCard(
        tone: _info,
        icon: Icons.fact_check_outlined,
        label: 'Por revisar',
        value: '${data.pendingReviews}',
        caption: data.pendingReviews > 0 ? 'Toca para revisar' : 'Al día',
        onTap: data.pendingReviews > 0 ? () => shell?.show('Asistencia') : null,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final perRow = constraints.maxWidth >= 1100
            ? 5
            : constraints.maxWidth >= 640
            ? 3
            : 2;
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

  Widget _dayLists(BuildContext context, ReportData data) {
    List<(EmployeeSummary, DayResult)> having(DayStatus status) => [
      for (final s in data.summaries)
        for (final d in s.days)
          if (d.status == status) (s, d),
    ];
    final onTime = having(DayStatus.onTime)
      ..sort((a, b) => a.$2.entryAt!.compareTo(b.$2.entryAt!));
    final late = having(DayStatus.late)
      ..sort((a, b) => b.$2.lateBy!.compareTo(a.$2.lateBy!));
    final absent = having(DayStatus.absent);
    final pending = having(DayStatus.pending);
    final noSchedule = data.summaries.where((s) => !s.hasSchedule).toList();
    final columns = [
      _StatusList(
        tone: _onTime,
        title: 'A tiempo',
        count: onTime.length,
        empty: 'Nadie todavía.',
        rows: [
          for (final (s, d) in onTime)
            _PersonRow(
              tone: _onTime,
              name: s.employee.name,
              department: s.departmentName,
              detail: _time(d.entryAt!),
            ),
        ],
      ),
      _StatusList(
        tone: _late,
        title: 'Llegaron tarde',
        count: late.length,
        empty: 'Sin retardos.',
        rows: [
          for (final (s, d) in late)
            _PersonRow(
              tone: _late,
              name: s.employee.name,
              department: s.departmentName,
              detail: _time(d.entryAt!),
              badge: '+${formatDuration(d.lateBy!)}',
            ),
        ],
      ),
      _StatusList(
        tone: _absent,
        title: 'No llegaron',
        count: absent.length,
        empty: pending.isEmpty ? 'Llegaron todos.' : 'Ninguna falta por ahora.',
        rows: [
          for (final (s, _) in absent)
            _PersonRow(
              tone: _absent,
              name: s.employee.name,
              department: s.departmentName,
              badge: 'Falta',
            ),
          if (pending.isNotEmpty) ...[
            const _Subheading('Aún en tolerancia'),
            for (final (s, _) in pending)
              _PersonRow(
                tone: _neutral,
                name: s.employee.name,
                department: s.departmentName,
                detail: 'Por llegar',
              ),
          ],
          if (noSchedule.isNotEmpty) ...[
            const _Subheading('Sin departamento'),
            for (final s in noSchedule)
              _PersonRow(
                tone: _neutral,
                name: s.employee.name,
                detail: 'Sin horario',
              ),
          ],
        ],
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 900) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < columns.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                columns[i],
              ],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < columns.length; i++) ...[
              if (i > 0) const SizedBox(width: 12),
              Expanded(child: columns[i]),
            ],
          ],
        );
      },
    );
  }

  Widget _concentrate(BuildContext context, ReportData data) {
    final text = Theme.of(context).textTheme;
    final header = text.bodySmall?.copyWith(fontWeight: FontWeight.w600);
    final rows = [...data.summaries]
      ..sort((a, b) {
        final byAbsent = b.absent.compareTo(a.absent);
        return byAbsent != 0 ? byAbsent : b.late.compareTo(a.late);
      });
    return _Panel(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showMinutes = constraints.maxWidth >= 720;
          Widget numberCell(String value, {_Tone? tone}) => SizedBox(
            width: 76,
            child: Align(
              alignment: Alignment.centerRight,
              child: tone == null
                  ? Text(
                      value,
                      style: const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    )
                  : _Badge(text: value, tone: tone),
            ),
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
                    Expanded(flex: 4, child: Text('Empleado', style: header)),
                    Expanded(flex: 5, child: Text('Asistencia', style: header)),
                    SizedBox(
                      width: 76,
                      child: Text(
                        'Retardos',
                        textAlign: TextAlign.right,
                        style: header,
                      ),
                    ),
                    if (showMinutes)
                      SizedBox(
                        width: 76,
                        child: Text(
                          'Min. tarde',
                          textAlign: TextAlign.right,
                          style: header,
                        ),
                      ),
                    SizedBox(
                      width: 76,
                      child: Text(
                        'Faltas',
                        textAlign: TextAlign.right,
                        style: header,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(),
              if (rows.isEmpty)
                const _Empty(
                  icon: Icons.groups_outlined,
                  text: 'No hay empleados con este filtro.',
                ),
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const Divider(),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 4,
                        child: _Identity(
                          name: rows[i].employee.name,
                          department:
                              rows[i].departmentName ?? 'Sin departamento',
                          tone: rows[i].absent > 0
                              ? _absent
                              : rows[i].late > 0
                              ? _late
                              : rows[i].attended > 0
                              ? _onTime
                              : _neutral,
                        ),
                      ),
                      Expanded(
                        flex: 5,
                        child: rows[i].hasSchedule
                            ? Padding(
                                padding: const EdgeInsets.only(right: 24),
                                child: _AttendanceBar(summary: rows[i]),
                              )
                            : Text(
                                'Sin horario asignado',
                                style: text.bodySmall,
                              ),
                      ),
                      if (rows[i].hasSchedule) ...[
                        numberCell(
                          '${rows[i].late}',
                          tone: rows[i].late > 0 ? _late : null,
                        ),
                        if (showMinutes)
                          numberCell(
                            rows[i].lateMinutes == 0
                                ? '—'
                                : formatDuration(rows[i].lateMinutes),
                          ),
                        numberCell(
                          '${rows[i].absent}',
                          tone: rows[i].absent > 0 ? _absent : null,
                        ),
                      ] else
                        SizedBox(width: showMinutes ? 228 : 152),
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

  Widget _holidayBanner(BuildContext context, List<ReportHoliday> holidays) {
    final names = [
      for (final h in holidays)
        _period == ReportPeriod.day
            ? h.name
            : '${h.name} (${h.day.day} de ${_months[h.day.month - 1]})',
    ];
    final scoped = holidays.any((h) => h.departmentId != null);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.infoTint,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.event_available, size: 20, color: AppColors.info),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _period == ReportPeriod.day
                  ? 'Día festivo: ${names.join(', ')}. No cuenta como falta${scoped ? ' para el departamento indicado' : ''}.'
                  : 'Festivos en el periodo: ${names.join(' · ')}. No cuentan como falta.',
            ),
          ),
          TextButton(
            onPressed: () => AdminShell.maybeOf(context)?.show('Días festivos'),
            child: const Text('Ver'),
          ),
        ],
      ),
    );
  }

  Widget _notice(BuildContext context, int withoutFace) => Container(
    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
    decoration: BoxDecoration(
      color: AppColors.lateTint,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        const Icon(Icons.face_retouching_off, size: 20, color: AppColors.late),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            withoutFace == 1
                ? '1 empleado no tiene rostro registrado y no puede checar con la cámara.'
                : '$withoutFace empleados no tienen rostro registrado y no pueden checar con la cámara.',
          ),
        ),
        TextButton(
          onPressed: () => AdminShell.maybeOf(context)?.show('Empleados'),
          child: const Text('Registrar rostros'),
        ),
      ],
    ),
  );
}

class _PeriodTab extends StatelessWidget {
  const _PeriodTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppColors.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? AppColors.line : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? AppColors.ink : AppColors.muted,
          ),
        ),
      ),
    ),
  );
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.tooltip, this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: AppColors.surface,
      shape: const CircleBorder(side: BorderSide(color: AppColors.line)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            icon,
            size: 22,
            color: onTap == null ? AppColors.line : AppColors.ink,
          ),
        ),
      ),
    ),
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: AppColors.surface,
      border: Border.all(color: AppColors.line),
      borderRadius: BorderRadius.circular(10),
    ),
    child: child,
  );
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.tone,
    required this.icon,
    required this.label,
    required this.value,
    this.caption,
    this.progress,
    this.onTap,
  });
  final _Tone tone;
  final IconData icon;
  final String label;
  final String value;
  final String? caption;
  final double? progress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final zero = value == '0' || value == '—';
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppColors.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: tone.tint,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon, size: 18, color: tone.strong),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(color: AppColors.muted),
                    ),
                  ),
                  if (onTap != null)
                    const Icon(
                      Icons.arrow_forward,
                      size: 18,
                      color: AppColors.info,
                    ),
                ],
              ),
              const SizedBox(height: 14),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.6, end: 1),
                duration: const Duration(milliseconds: 260),
                key: ValueKey(value),
                builder: (context, t, child) =>
                    Opacity(opacity: t, child: child),
                child: Text(
                  value,
                  style: text.headlineMedium?.copyWith(
                    fontSize: 32,
                    color: zero ? AppColors.ink : tone.strong,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              if (progress != null) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: progress!.clamp(0, 1)),
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutCubic,
                    builder: (context, v, _) => LinearProgressIndicator(
                      value: v,
                      minHeight: 6,
                      backgroundColor: AppColors.selected,
                      color: v >= 0.9
                          ? AppColors.onTime
                          : v >= 0.7
                          ? AppColors.late
                          : AppColors.absent,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                caption ?? ' ',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(
                  color: onTap != null ? AppColors.info : AppColors.muted,
                  fontWeight: onTap != null ? FontWeight.w600 : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusList extends StatelessWidget {
  const _StatusList({
    required this.tone,
    required this.title,
    required this.count,
    required this.empty,
    required this.rows,
  });
  final _Tone tone;
  final String title;
  final int count;
  final String empty;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(height: 3, color: tone.strong),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              _Badge(text: '$count', tone: tone),
            ],
          ),
        ),
        const Divider(),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: Text(empty, style: Theme.of(context).textTheme.bodySmall),
          )
        else ...[
          const SizedBox(height: 4),
          ...rows,
          const SizedBox(height: 8),
        ],
      ],
    ),
  );
}

class _Identity extends StatelessWidget {
  const _Identity({required this.name, this.department, required this.tone});
  final String name;
  final String? department;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => part[0].toUpperCase())
        .join();
    return Row(
      children: [
        CircleAvatar(
          radius: 17,
          backgroundColor: tone.tint,
          child: Text(
            initials,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: tone.strong,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (department != null)
                Text(
                  department!,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.tone,
    required this.name,
    this.department,
    this.detail,
    this.badge,
  });
  final _Tone tone;
  final String name;
  final String? department;
  final String? detail;
  final String? badge;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: _Identity(name: name, department: department, tone: tone),
        ),
        if (detail != null) ...[
          const SizedBox(width: 8),
          Text(
            detail!,
            style: const TextStyle(
              color: AppColors.muted,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
        if (badge != null) ...[
          const SizedBox(width: 8),
          _Badge(text: badge!, tone: tone),
        ],
      ],
    ),
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.tone});
  final String text;
  final _Tone tone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: tone.tint,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: tone.strong,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );
}

/// Barra con la proporción de días a tiempo, tarde y faltas del periodo.
class _AttendanceBar extends StatelessWidget {
  const _AttendanceBar({required this.summary});
  final EmployeeSummary summary;

  @override
  Widget build(BuildContext context) {
    final total = summary.workDays;
    final parts = [
      (summary.onTime, AppColors.onTime),
      (summary.late, AppColors.late),
      (summary.absent, AppColors.absent),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: total == 0
                ? const ColoredBox(color: AppColors.selected)
                : Row(
                    children: [
                      for (final (count, color) in parts)
                        if (count > 0)
                          Expanded(
                            flex: count,
                            child: ColoredBox(color: color),
                          ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          total == 0
              ? 'Sin días laborables en el periodo'
              : '${summary.attended} de $total días · ${summary.onTime} a tiempo',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _Subheading extends StatelessWidget {
  const _Subheading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(letterSpacing: 0.6, fontWeight: FontWeight.w600),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(32),
    child: Column(
      children: [
        Icon(icon, size: 32, color: AppColors.muted),
        const SizedBox(height: 8),
        Text(text, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}
