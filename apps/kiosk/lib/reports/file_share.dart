import 'package:flutter/services.dart';

const xlsxMimeType =
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

const _channel = MethodChannel('accesos/compartir');

/// Abre el menú de Android para enviar el archivo por WhatsApp, correo, Drive…
Future<void> shareFile({
  required String name,
  required Uint8List bytes,
  String mimeType = xlsxMimeType,
  String title = 'Compartir',
}) => _channel.invokeMethod<void>('share', {
  'name': name,
  'bytes': bytes,
  'mimeType': mimeType,
  'title': title,
});
