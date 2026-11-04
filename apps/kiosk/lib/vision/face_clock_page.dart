import 'dart:async';

import 'package:flutter/material.dart';

import '../attendance/attendance_store.dart';
import 'face_capture_panel.dart';
import 'face_matching.dart';
import 'face_template_store.dart';

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

class _FaceClockPageState extends State<FaceClockPage> {
  bool _scanning = true;
  bool _saving = false;
  FaceMatch? _match;
  AttendanceKind? _next;
  String? _message;
  Timer? _timer;

  void _reset({bool scanAgain = false}) {
    _timer?.cancel();
    if (mounted) {
      setState(() {
        _scanning = scanAgain;
        _match = null;
        _next = null;
        _message = null;
      });
    }
  }

  Future<void> _identify(List<List<double>> samples) async {
    try {
      final match = await widget.faces.identify(samples);
      final next = await widget.attendance.nextFor(match.employeeNumber);
      if (!mounted || !_scanning) return;
      setState(() {
        _match = match;
        _next = next;
        _scanning = false;
        _message = next == null
            ? 'Ya registraste tu entrada y salida de hoy.'
            : 'Confirma tu ${next.label.toLowerCase()}.';
      });
      _timer = Timer(
        const Duration(seconds: 20),
        () => _reset(scanAgain: true),
      );
    } on FaceRuleError catch (error) {
      if (mounted && _scanning) {
        setState(() {
          _scanning = false;
          _message = error.message;
        });
      }
    } catch (_) {
      if (mounted && _scanning) {
        setState(() {
          _scanning = false;
          _message = 'No se pudo identificar el rostro. Reintenta o solicita apoyo a RH.';
        });
      }
    }
  }

  Future<void> _record() async {
    final match = _match;
    final kind = _next;
    if (_saving || match == null || kind == null) return;
    _timer?.cancel();
    setState(() => _saving = true);
    try {
      await widget.attendance.recordFacial(match, kind);
      final now = DateTime.now();
      if (mounted) {
        setState(
          () => _message =
              '${kind.label} registrada para ${match.employeeName}.\n${now.day}/${now.month}/${now.year} · ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
        );
      }
    } on AttendanceRuleError catch (error) {
      if (mounted) setState(() => _message = error.message);
    } on FaceRuleError catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'No se pudo guardar. Vuelve a identificarte para comprobar el movimiento.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _match = null;
          _next = null;
        });
        _timer = Timer(
          const Duration(seconds: 3),
          () => _reset(scanAgain: true),
        );
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Entradas y salidas'),
      actions: [
        TextButton.icon(
          onPressed: _saving
              ? null
              : () {
                  _reset();
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
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              const Text(
                'Mira a la cámara y sigue las indicaciones. Funciona sin internet.',
              ),
              const SizedBox(height: 24),
              if (_scanning) ...[
                FaceCapturePanel(onSamples: _identify),
                TextButton(
                  onPressed: () => _reset(),
                  child: const Text('Cancelar'),
                ),
              ] else if (_match != null) ...[
                Text(
                  _match!.employeeName,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Text('Número de empleado: ${_match!.employeeNumber}'),
                if (_next != null)
                  FilledButton(
                    onPressed: _saving ? null : _record,
                    child: Text(
                      _saving
                          ? 'Guardando…'
                          : 'Registrar ${_next!.label.toLowerCase()}',
                    ),
                  ),
                TextButton(
                  onPressed: _saving ? null : () => _reset(scanAgain: true),
                  child: const Text('Volver al inicio'),
                ),
              ] else
                FilledButton.icon(
                  onPressed: _saving
                      ? null
                      : () {
                          _timer?.cancel();
                          setState(() {
                            _scanning = true;
                            _message = null;
                          });
                        },
                  icon: const Icon(Icons.face),
                  label: const Text('Checar con rostro'),
                ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Semantics(liveRegion: true, child: Text(_message!)),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
