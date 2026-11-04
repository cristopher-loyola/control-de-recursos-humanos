import 'package:flutter/material.dart';

import '../employees/employee_store.dart';
import 'consent_store.dart';
import 'face_capture_panel.dart';
import 'face_matching.dart';
import 'face_template_store.dart';

class FaceEnrollmentPage extends StatefulWidget {
  const FaceEnrollmentPage({
    super.key,
    required this.employee,
    required this.consents,
    required this.faces,
  });
  final Employee employee;
  final ConsentStore consents;
  final FaceTemplateStore faces;

  @override
  State<FaceEnrollmentPage> createState() => _FaceEnrollmentPageState();
}

class _FaceEnrollmentPageState extends State<FaceEnrollmentPage> {
  final _folio = TextEditingController();
  bool _loading = true;
  bool _activeConsent = false;
  bool _confirmed = false;
  bool _capturing = false;
  bool _saved = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await widget.consents.list();
      final item = items
          .where((item) => item.employeeNumber == widget.employee.number)
          .firstOrNull;
      if (mounted) setState(() => _activeConsent = item?.active == true);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'No se pudo consultar el consentimiento. Vuelve a abrir esta pantalla.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _begin() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!_activeConsent) {
        await widget.consents.record(
          widget.employee.number,
          ConsentKind.recorded,
          _folio.text,
        );
      }
      await widget.consents.requireActiveConsent(widget.employee.number);
      if (mounted) {
        setState(() {
          _activeConsent = true;
          _capturing = true;
        });
      }
    } on ConsentRuleError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'No se pudo iniciar. Verifica tu acceso e intenta nuevamente.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(List<List<double>> samples) async {
    try {
      await widget.faces.enroll(widget.employee.number, samples);
      if (mounted) {
        setState(() {
          _saved = true;
          _capturing = false;
        });
      }
    } on FaceRuleError catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _capturing = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'No se pudo guardar el rostro. Vuelve a intentarlo.';
          _capturing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _folio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Registrar rostro')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                widget.employee.name,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              Text('Número de empleado: ${widget.employee.number}'),
              const SizedBox(height: 20),
              if (_loading)
                const LinearProgressIndicator()
              else if (_saved) ...[
                const Icon(Icons.check_circle_outline, size: 64),
                const Text(
                  'Rostro asociado al empleado. Ya puede checar con la cámara.',
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Terminar'),
                ),
              ] else if (_capturing)
                FaceCapturePanel(
                  guidedEnrollment: true,
                  beforeStart: () async {
                    widget.faces.authorizeEnrollment();
                    await widget.consents.requireActiveConsent(
                      widget.employee.number,
                    );
                  },
                  onSamples: _save,
                )
              else ...[
                const Text(
                  'Confirma al trabajador. Coloca su cara de frente dentro del contorno y que se mantenga quieto unos segundos. La captura es automática.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'El rostro se guarda cifrado en esta tablet para reconocer al empleado sin internet. No se guardan las fotografías de esta captura.',
                ),
                if (widget.employee.hasFace)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'Al completar la captura se reemplazará el rostro registrado para este empleado.',
                    ),
                  ),
                if (!_activeConsent) ...[
                  const SizedBox(height: 20),
                  const Text(
                    'Primero registra el folio del consentimiento firmado. Conserva el documento original.',
                  ),
                  TextField(
                    controller: _folio,
                    maxLength: 120,
                    decoration: const InputDecoration(
                      labelText: 'Folio del documento firmado',
                    ),
                  ),
                ],
                CheckboxListTile(
                  value: _confirmed,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    _activeConsent
                        ? 'Verifiqué al trabajador y su consentimiento vigente.'
                        : 'Verifiqué al trabajador y tengo su consentimiento firmado.',
                  ),
                  onChanged: (value) =>
                      setState(() => _confirmed = value ?? false),
                ),
                FilledButton(
                  onPressed: _confirmed ? _begin : null,
                  child: const Text('Capturar rostro'),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
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
    ),
  );
}
