import 'package:flutter/material.dart';

import 'audit_store.dart';

class AuditPage extends StatefulWidget {
  const AuditPage({super.key, required this.store});
  final AuditStore store;

  @override
  State<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends State<AuditPage> {
  List<AuditEntry> _entries = [];
  bool _loading = true;
  bool _more = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool append = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.store.list(
        beforeId: append && _entries.isNotEmpty ? _entries.last.id : null,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _entries = append ? [..._entries, ...rows] : rows;
        _more = rows.length == AuditStore.pageSize;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'No se pudo cargar el historial. Vuelve a intentarlo.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  String _date(DateTime value) {
    final date = value.toLocal();
    String two(int part) => part.toString().padLeft(2, '0');
    return '${two(date.day)}/${two(date.month)}/${date.year} · ${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Historial de acciones'),
      actions: [
        IconButton(
          onPressed: _loading ? null : () => _load(),
          tooltip: 'Actualizar historial',
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
                'Consulta quién realizó cada acción y cuándo. Las fechas corresponden al reloj de la tablet.',
              ),
              const SizedBox(height: 8),
              const Text(
                'Los registros de esta pantalla no se pueden editar ni eliminar desde la aplicación.',
              ),
              const SizedBox(height: 24),
              if (_error != null) ...[
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                TextButton(
                  onPressed: _loading ? null : () => _load(),
                  child: const Text('Volver a intentar'),
                ),
              ],
              if (!_loading && _error == null && _entries.isEmpty)
                const Text('Aún no hay acciones registradas.'),
              for (final entry in _entries)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.action.label,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: entry.action == AuditAction.loginFailed
                                    ? Theme.of(context).colorScheme.error
                                    : null,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(entry.description),
                        const SizedBox(height: 8),
                        Text(
                          '${entry.actor ?? 'Acceso no autenticado'} · ${_date(entry.time)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (_more && !_loading)
                TextButton(
                  onPressed: () => _load(append: true),
                  child: const Text('Ver acciones anteriores'),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
