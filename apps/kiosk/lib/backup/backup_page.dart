import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'backup_service.dart';
import 'backup_snapshot.dart';

class BackupPage extends StatefulWidget {
  const BackupPage({super.key, required this.service});
  final BackupService service;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool _busy = false;
  String? _message;

  Future<void> _export() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final snapshot = await widget.service.capture();
      final timestamp = snapshot.createdAt.millisecondsSinceEpoch;
      final saved = await FilePicker.saveFile(
        fileName: 'respaldo-rh-$timestamp.json',
        bytes: snapshot.encode(),
        mimeType: 'application/json',
        dialogTitle: 'Guardar respaldo',
      );
      if (!mounted) {
        return;
      }
      setState(
        () => _message = saved == null
            ? 'Exportación cancelada.'
            : 'Respaldo guardado: ${snapshot.employees.length} empleados y ${snapshot.events.length} movimientos.',
      );
    } on InvalidBackup catch (error) {
      if (mounted) {
        setState(() => _message = error.message);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'No se pudo guardar el respaldo. Verifica el espacio y vuelve a intentarlo.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _restore() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    var restoring = false;
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: 'Seleccionar respaldo',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (file == null) {
        if (mounted) {
          setState(() => _message = 'Restauración cancelada.');
        }
        return;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.readAsByteStream()) {
        if (builder.length + chunk.length > BackupSnapshot.maxBytes) {
          throw const InvalidBackup('El respaldo supera el límite de 20 MB.');
        }
        builder.add(chunk);
      }
      final snapshot = BackupSnapshot.decode(builder.takeBytes());
      if (!mounted) {
        return;
      }
      final date = snapshot.createdAt.toLocal();
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('¿Reemplazar los datos actuales?'),
          content: Text(
            'Respaldo del ${date.day}/${date.month}/${date.year}.\n\n'
            '${snapshot.employees.length} empleados\n${snapshot.events.length} movimientos\n\n'
            'Se reemplazarán TODOS los empleados y asistencias de esta tablet. '
            'Los registros posteriores al respaldo dejarán de estar en la aplicación. '
            'Si necesitas conservarlos, cancela y exporta primero un respaldo actual.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Reemplazar y restaurar'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        if (mounted) {
          setState(
            () => _message =
                'Restauración cancelada. No se modificaron tus datos.',
          );
        }
        return;
      }
      restoring = true;
      await widget.service.restore(snapshot);
      if (mounted) {
        setState(
          () => _message =
              'Restauración completada: ${snapshot.employees.length} empleados y ${snapshot.events.length} movimientos.',
        );
      }
    } on InvalidBackup catch (error) {
      if (mounted) {
        setState(
          () => _message = '${error.message} No se modificaron tus datos.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = restoring
              ? 'La restauración falló y se revirtieron los cambios. Vuelve a consultar tus registros.'
              : 'No se pudo leer el archivo. No se modificaron tus datos.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Respaldos')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 750),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  'Protege tus registros',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 16),
                const Text(
                  'El respaldo incluye empleados y todas sus entradas y salidas.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'Conserva una copia en tu computadora o en una memoria externa. '
                  'Guardar únicamente en esta tablet no protege frente a su pérdida.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'El archivo contiene nombres y asistencias sin cifrar. Guárdalo en un lugar de acceso restringido.',
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _busy ? null : _export,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Exportar respaldo'),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _restore,
                  icon: const Icon(Icons.restore),
                  label: const Text('Restaurar desde archivo'),
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Semantics(liveRegion: true, child: Text(_message!)),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
