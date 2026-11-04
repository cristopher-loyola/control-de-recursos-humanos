import 'dart:async';

import 'package:flutter/material.dart';

import '../attendance/attendance_store.dart';
import 'face_capture_panel.dart';
import 'face_matching.dart';
import 'face_template_store.dart';

/// Checador sin toques: reconoce, registra el movimiento que corresponde y
/// vuelve a escanear. La cámara queda encendida entre una persona y otra.
class FaceClockPage extends StatefulWidget {
  const FaceClockPage({
    super.key,
    required this.faces,
    required this.attendance,
    required this.onOpenAdmin,
  });
  final FaceTemplateStore faces;
  final AttendanceStore attendance;
  final VoidCallback onOpenAdmin;
  @override
  State<FaceClockPage> createState() => _FaceClockPageState();
}

enum _Outcome { success, notice, failure }

class _FaceClockPageState extends State<FaceClockPage> {
  static const _successPause = Duration(seconds: 4);
  static const _failurePause = Duration(milliseconds: 2500);

  bool _scanning = true;
  String? _title;
  String? _detail;
  _Outcome _outcome = _Outcome.success;
  Timer? _timer;

  void _show(_Outcome outcome, String title, String? detail, Duration pause) {
    if (!mounted) return;
    setState(() {
      _scanning = false;
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
        _title = null;
        _detail = null;
      });
    }
  }

  Future<void> _identify(List<List<double>> samples) async {
    if (!_scanning) return;
    try {
      final match = await widget.faces.identify(samples);
      final next = await widget.attendance.nextFor(match.employeeNumber);
      if (next == null) {
        _show(
          _Outcome.notice,
          match.employeeName,
          'Ya registraste tu entrada y salida de hoy.',
          _successPause,
        );
        return;
      }
      await widget.attendance.recordFacial(match, next);
      final now = DateTime.now();
      _show(
        _Outcome.success,
        '${next.label} · ${match.employeeName}',
        'Número ${match.employeeNumber} · '
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}. '
            'Si no eres tú, avisa a RH.',
        _successPause,
      );
    } on AttendanceRuleError catch (error) {
      _show(_Outcome.notice, error.message, null, _successPause);
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

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (_outcome) {
      _Outcome.success => theme.colorScheme.primary,
      _Outcome.notice => theme.colorScheme.onSurface,
      _Outcome.failure => theme.colorScheme.error,
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('Entradas y salidas'),
        actions: [
          TextButton.icon(
            onPressed: () {
              _timer?.cancel();
              widget.onOpenAdmin();
            },
            icon: const Icon(Icons.admin_panel_settings_outlined),
            label: const Text('Administrar'),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  'Checa con tu rostro',
                  style: theme.textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Mírate en la pantalla. Se registra solo. Funciona sin internet.',
                ),
                const SizedBox(height: 16),
                if (_title != null)
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        border: Border.all(color: color, width: 2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _title!,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              color: color,
                            ),
                          ),
                          if (_detail != null) ...[
                            const SizedBox(height: 4),
                            Text(_detail!),
                          ],
                        ],
                      ),
                    ),
                  ),
                FaceCapturePanel(onSamples: _identify, active: _scanning),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
