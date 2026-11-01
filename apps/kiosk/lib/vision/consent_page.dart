import 'package:flutter/material.dart';

import 'consent_store.dart';

class ConsentPage extends StatefulWidget {
  const ConsentPage({super.key, required this.store});

  final ConsentStore store;

  @override
  State<ConsentPage> createState() => _ConsentPageState();
}

class _ConsentPageState extends State<ConsentPage> {
  List<ConsentItem> _items = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _message;

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
      final items = await widget.store.list();
      if (mounted) {
        setState(() => _items = items);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'No se pudo consultar el registro de consentimientos.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _record(ConsentItem item) async {
    final kind = item.active ? ConsentKind.revoked : ConsentKind.recorded;
    final form = GlobalKey<FormState>();
    var reference = '';
    final folio = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          kind == ConsentKind.recorded
              ? 'Registrar consentimiento de ${item.employeeName}'
              : 'Registrar revocación de ${item.employeeName}',
        ),
        content: Form(
          key: form,
          child: TextFormField(
            autofocus: true,
            maxLength: 120,
            onChanged: (value) => reference = value,
            decoration: InputDecoration(
              labelText: kind == ConsentKind.recorded
                  ? 'Folio del consentimiento firmado'
                  : 'Folio de la revocación firmada',
              helperText:
                  'El documento firmado debe conservarse fuera de esta tablet.',
              helperMaxLines: 2,
            ),
            validator: (value) => (value?.trim().length ?? 0) < 5
                ? 'Escribe un folio de al menos 5 caracteres.'
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
                Navigator.of(dialogContext).pop(reference.trim());
              }
            },
            child: const Text('Guardar folio'),
          ),
        ],
      ),
    );
    if (folio == null || !mounted) {
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await widget.store.record(item.employeeNumber, kind, folio);
      if (mounted) {
        setState(() => _message = 'Folio guardado para ${item.employeeName}.');
        await _load();
      }
    } on ConsentRuleError catch (error) {
      if (mounted) {
        setState(() => _message = error.message);
        await _load();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'No se pudo guardar el folio. Vuelve a intentarlo.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  String _date(DateTime date) {
    final local = date.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}/${local.year}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Consentimientos')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 850),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Documentos de consentimiento',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Registra el folio de un documento firmado antes del enrolamiento facial. Esta pantalla no guarda el documento ni captura rostros.',
              ),
              const SizedBox(height: 8),
              const Text(
                'Conserva el original firmado de forma segura. Un folio escrito aquí no sustituye ese documento.',
              ),
              const SizedBox(height: 20),
              if (_loading || _saving) const LinearProgressIndicator(),
              if (_error != null) ...[
                Text(_error!),
                TextButton(
                  onPressed: _load,
                  child: const Text('Volver a intentar'),
                ),
              ],
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Semantics(liveRegion: true, child: Text(_message!)),
                ),
              if (!_loading && _error == null && _items.isEmpty)
                const Text('Primero registra un empleado.'),
              for (final item in _items)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.employeeName,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text('Número: ${item.employeeNumber}'),
                        const SizedBox(height: 8),
                        Text(
                          item.active
                              ? 'Documento de consentimiento registrado'
                              : item.kind == ConsentKind.revoked
                              ? 'Consentimiento revocado'
                              : 'Sin documento registrado',
                        ),
                        if (item.documentReference != null) ...[
                          const SizedBox(height: 4),
                          Text('Folio: ${item.documentReference}'),
                        ],
                        if (item.occurredAt != null) ...[
                          const SizedBox(height: 4),
                          Text('${_date(item.occurredAt!)} · ${item.actor}'),
                        ],
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: _saving || _loading
                              ? null
                              : () => _record(item),
                          child: Text(
                            item.active
                                ? 'Registrar revocación'
                                : 'Registrar folio firmado',
                          ),
                        ),
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
