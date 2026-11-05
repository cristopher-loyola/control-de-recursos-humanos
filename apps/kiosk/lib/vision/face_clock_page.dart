import 'dart:async';

import 'package:flutter/material.dart';

import '../attendance/attendance_store.dart';
import '../theme/app_theme.dart';
import 'face_capture_panel.dart';
import 'face_matching.dart';
import 'face_template_store.dart';

/// Checador: reconoce el rostro y el empleado elige Entrada o Salida. La cámara
/// queda encendida entre una persona y otra.
class FaceClockPage extends StatefulWidget {
  const FaceClockPage({
    super.key,
    required this.faces,
    required this.attendance,
    required this.onOpenAdmin,
    this.organizationName,
  });
  final FaceTemplateStore faces;
  final AttendanceStore attendance;
  final VoidCallback onOpenAdmin;
  final String? organizationName;
  @override
  State<FaceClockPage> createState() => _FaceClockPageState();
}

enum _Outcome { success, notice, failure }

class _FaceClockPageState extends State<FaceClockPage> {
  static const _resultPause = Duration(seconds: 4);
  static const _failurePause = Duration(milliseconds: 2500);
  // Menor que la vigencia de la identificación (20 s).
  static const _choiceTimeout = Duration(seconds: 15);
  // Quien se queda frente a la cámara no vuelve a checar por accidente.
  static const _cooldown = Duration(minutes: 1);

  bool _scanning = true;
  bool _saving = false;
  FaceMatch? _match;
  AttendanceKind? _next;
  AttendanceEvent? _last;
  String? _title;
  String? _detail;
  _Outcome _outcome = _Outcome.success;
  Timer? _timer;

  void _show(_Outcome outcome, String title, String? detail, Duration pause) {
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _match = null;
      _outcome = outcome;
      _title = title;
      _detail = detail;
    });
    _timer?.cancel();
    _timer = Timer(pause, _scanAgain);
  }

  void _scanAgain() {
    _timer?.cancel();
    if (mounted) {
      setState(() {
        _scanning = true;
        _match = null;
        _next = null;
        _last = null;
        _title = null;
        _detail = null;
      });
    }
  }

  static String _time(DateTime date) {
    final local = date.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _identify(List<List<double>> samples) async {
    if (!_scanning) return;
    try {
      final match = await widget.faces.identify(samples);
      final last = await widget.attendance.lastFor(match.employeeNumber);
      if (last != null &&
          DateTime.now().toUtc().difference(last.occurredAt) < _cooldown) {
        _show(
          _Outcome.notice,
          match.employeeName,
          'Ya registraste tu ${last.kind.label.toLowerCase()} a las ${_time(last.occurredAt)}.',
          _resultPause,
        );
        return;
      }
      final next = await widget.attendance.nextFor(match.employeeNumber);
      if (next == null) {
        _show(
          _Outcome.notice,
          match.employeeName,
          'Ya registraste tu entrada y salida de hoy.',
          _resultPause,
        );
        return;
      }
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _match = match;
        _next = next;
        _last = last;
        _title = null;
      });
      _timer?.cancel();
      _timer = Timer(_choiceTimeout, _scanAgain);
    } on AttendanceRuleError catch (error) {
      _show(_Outcome.notice, error.message, null, _resultPause);
    } on FaceRuleError catch (error) {
      _show(_Outcome.failure, error.message, null, _failurePause);
    } catch (_) {
      _show(
        _Outcome.failure,
        'No se pudo identificar el rostro.',
        'Vuelve a intentarlo o solicita apoyo a RH.',
        _failurePause,
      );
    }
  }

  Future<void> _record(AttendanceKind kind) async {
    final match = _match;
    if (_saving || match == null) return;
    _timer?.cancel();
    setState(() => _saving = true);
    try {
      await widget.attendance.recordFacial(match, kind);
      _show(
        _Outcome.success,
        '${kind.label} registrada',
        '${match.employeeName} · ${_time(DateTime.now())}. Si no eres tú, avisa a RH.',
        _resultPause,
      );
    } on AttendanceRuleError catch (error) {
      _show(_Outcome.notice, error.message, null, _resultPause);
    } on FaceRuleError catch (error) {
      _show(_Outcome.failure, error.message, null, _failurePause);
    } catch (_) {
      _show(
        _Outcome.failure,
        'No se pudo guardar.',
        'Vuelve a identificarte para comprobar el movimiento.',
        _failurePause,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Por qué un botón está desactivado, a partir de la última checada.
  String? _blockedReason(AttendanceKind kind) {
    if (kind == _next) return null;
    final last = _last;
    if (kind == AttendanceKind.entry && last?.kind == AttendanceKind.entry) {
      return 'Entrada registrada a las ${_time(last!.occurredAt)}';
    }
    if (kind == AttendanceKind.exit) return 'Primero registra tu entrada';
    return 'No disponible';
  }

  Color? get _highlight {
    if (_match != null) return AppColors.accent;
    if (_title == null) return null;
    return switch (_outcome) {
      _Outcome.success => AppColors.accent,
      _Outcome.notice => null,
      _Outcome.failure => AppColors.danger,
    };
  }

  Widget _idle(BuildContext context) => Column(
    key: const ValueKey('idle'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Párate frente a la cámara',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 6),
      Text(
        'Te reconocemos en un momento y eliges si es entrada o salida.',
        style: Theme.of(context).textTheme.bodyLarge
            ?.copyWith(color: AppColors.muted),
      ),
    ],
  );

  Widget _result(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (icon, color) = switch (_outcome) {
      _Outcome.success => (Icons.check_circle_outline, AppColors.accent),
      _Outcome.notice => (Icons.info_outline, AppColors.ink),
      _Outcome.failure => (Icons.error_outline, AppColors.danger),
    };
    return Column(
      key: ValueKey('result-$_title-$_detail'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 36),
        const SizedBox(height: 12),
        Text(
          _title!,
          style: text.headlineSmall?.copyWith(color: color, fontSize: 26),
        ),
        if (_detail != null) ...[
          const SizedBox(height: 6),
          Text(
            _detail!,
            style: text.bodyLarge?.copyWith(color: AppColors.muted),
          ),
        ],
      ],
    );
  }

  Widget _choice(BuildContext context) {
    final match = _match!;
    final text = Theme.of(context).textTheme;
    Widget option(AttendanceKind kind, IconData icon) {
      final reason = _blockedReason(kind);
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 76,
              child: reason == null
                  ? FilledButton.icon(
                      onPressed: _saving ? null : () => _record(kind),
                      icon: Icon(icon, size: 26),
                      label: Text(
                        kind.label,
                        style: const TextStyle(fontSize: 20),
                      ),
                    )
                  : OutlinedButton.icon(
                      onPressed: null,
                      icon: Icon(icon, size: 26),
                      label: Text(
                        kind.label,
                        style: const TextStyle(fontSize: 20),
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              child: Text(reason ?? '', style: text.bodySmall),
            ),
          ],
        ),
      );
    }

    return Column(
      key: ValueKey('choice-${match.employeeNumber}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Hola, ${match.employeeName}',
          style: text.headlineSmall?.copyWith(fontSize: 28),
        ),
        const SizedBox(height: 4),
        Text(
          'No. ${match.employeeNumber} · ¿Qué vas a registrar?',
          style: text.bodyLarge?.copyWith(color: AppColors.muted),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            option(AttendanceKind.entry, Icons.login),
            const SizedBox(width: 12),
            option(AttendanceKind.exit, Icons.logout),
          ],
        ),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: AppColors.muted,
            padding: EdgeInsets.zero,
          ),
          onPressed: _saving ? null : _scanAgain,
          child: const Text('No soy yo'),
        ),
      ],
    );
  }

  Widget _state(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 260),
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeInCubic,
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    ),
    layoutBuilder: (current, previous) =>
        Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
    child: _match != null
        ? _choice(context)
        : _title != null
        ? _result(context)
        : _idle(context),
  );

  Widget _camera() => FaceCapturePanel(
    onSamples: _identify,
    active: _scanning,
    fill: true,
    highlight: _highlight,
  );

  Widget _adminLink() => TextButton.icon(
    style: TextButton.styleFrom(foregroundColor: AppColors.muted),
    onPressed: () {
      _timer?.cancel();
      widget.onOpenAdmin();
    },
    icon: const Icon(Icons.lock_outline, size: 18),
    label: const Text('Administrar'),
  );

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 420,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 40, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _Header(organizationName: widget.organizationName),
                            // Centrado en el espacio libre; si no alcanza, se desplaza.
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, box) =>
                                    SingleChildScrollView(
                                      child: ConstrainedBox(
                                        constraints: BoxConstraints(
                                          minHeight: box.maxHeight,
                                        ),
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: _state(context),
                                        ),
                                      ),
                                    ),
                              ),
                            ),
                            _adminLink(),
                          ],
                        ),
                      ),
                    ),
                    Expanded(child: _camera()),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _Header(
                            organizationName: widget.organizationName,
                            compact: true,
                          ),
                        ),
                        _adminLink(),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Expanded(child: _camera()),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 200,
                      child: SingleChildScrollView(child: _state(context)),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Saludo, hora en vivo y fecha.
class _Header extends StatefulWidget {
  const _Header({this.organizationName, this.compact = false});
  final String? organizationName;
  final bool compact;

  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  static const _days = [
    'lunes',
    'martes',
    'miércoles',
    'jueves',
    'viernes',
    'sábado',
    'domingo',
  ];
  static const _months = [
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
  late DateTime _now = DateTime.now();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      if (now.minute != _now.minute && mounted) setState(() => _now = now);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final greeting = _now.hour < 12
        ? 'Buenos días'
        : _now.hour < 19
        ? 'Buenas tardes'
        : 'Buenas noches';
    final time =
        '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.organizationName ?? 'Entradas y salidas',
          style: text.bodyMedium?.copyWith(
            color: AppColors.muted,
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(height: widget.compact ? 4 : 20),
        Text(
          greeting,
          style: text.titleLarge?.copyWith(color: AppColors.muted),
        ),
        Text(
          time,
          style: TextStyle(
            // Más chico en pantallas bajas para dejar sitio a los botones.
            fontSize: widget.compact
                ? 56
                : MediaQuery.sizeOf(context).height < 760
                ? 80
                : 104,
            height: 1,
            fontWeight: FontWeight.w300,
            letterSpacing: -2,
            color: AppColors.ink,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${_days[_now.weekday - 1]} ${_now.day} de ${_months[_now.month - 1]}',
          style: text.titleMedium?.copyWith(fontWeight: FontWeight.w400),
        ),
      ],
    );
  }
}
