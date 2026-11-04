import 'package:flutter/services.dart';

import 'face_capture_quality.dart';

abstract interface class TemplateCipher {
  Future<Uint8List> seal(Uint8List bytes, String context);
  Future<Uint8List> unseal(Uint8List bytes, String context);
}

class FaceEngine implements TemplateCipher {
  static const channel = MethodChannel('accesos/face_engine');
  static const modelId = 'sface-2021dec-0ba9fbfa-v1';

  Future<void> initialize() async {
    await channel.invokeMethod<bool>('initialize');
  }

  Future<bool> cameraRotation() async =>
      await channel.invokeMethod<bool>('cameraRotation') ?? false;
  Future<void> setCameraRotation(bool value) =>
      channel.invokeMethod<void>('setCameraRotation', value);

  Future<List<double>> extract({
    required Uint8List bytes,
    required int width,
    required int height,
    required int rotation,
    required List<double> landmarks,
  }) async {
    final values = await channel.invokeListMethod<double>('extract', {
      'bytes': bytes,
      'width': width,
      'height': height,
      'rotation': rotation,
      'landmarks': landmarks,
    });
    if (values == null || values.length != 128) {
      throw StateError('No se obtuvo una plantilla facial válida.');
    }
    return values;
  }

  /// YuNet (OpenCV Zoo) sobre el cuadro ya derecho. Guarda el cuadro para [extractDetected].
  Future<FaceDetection> detect({
    required Uint8List bytes,
    required int width,
    required int height,
    required int rotation,
  }) async {
    final result = await channel.invokeMapMethod<String, Object?>('detect', {
      'bytes': bytes,
      'width': width,
      'height': height,
      'rotation': rotation,
    });
    if (result == null) throw StateError('No se pudo analizar el cuadro.');
    final rows = (result['faces'] as List).cast<List>();
    return FaceDetection(
      Size(
        (result['width'] as num).toDouble(),
        (result['height'] as num).toDouble(),
      ),
      [
        for (var i = 0; i < rows.length; i++)
          DetectedFace.fromRow(i, rows[i].cast<num>()),
      ],
    );
  }

  /// Plantilla SFace del rostro [index] del último cuadro analizado.
  Future<List<double>> extractDetected(int index) async {
    final values = await channel.invokeListMethod<double>(
      'extractDetected',
      index,
    );
    if (values == null || values.length != 128) {
      throw StateError('No se obtuvo una plantilla facial válida.');
    }
    return values;
  }

  @override
  Future<Uint8List> seal(Uint8List bytes, String context) async =>
      (await channel.invokeMethod<Uint8List>('seal', {
        'bytes': bytes,
        'context': context,
      }))!;

  @override
  Future<Uint8List> unseal(Uint8List bytes, String context) async =>
      (await channel.invokeMethod<Uint8List>('unseal', {
        'bytes': bytes,
        'context': context,
      }))!;
}

class FaceDetection {
  const FaceDetection(this.size, this.faces);
  final Size size;
  final List<DetectedFace> faces;
}

class DetectedFace {
  const DetectedFace(this.index, this.box, this.landmarks, this.score);

  factory DetectedFace.fromRow(int index, List<num> row) {
    if (row.length != 15) throw StateError('Detección facial inválida.');
    final v = row.map((value) => value.toDouble()).toList();
    return DetectedFace(index, Rect.fromLTWH(v[0], v[1], v[2], v[3]), [
      for (var i = 4; i < 14; i += 2) Offset(v[i], v[i + 1]),
    ], v[14]);
  }

  /// Posición en la respuesta nativa; [FaceEngine.extractDetected] la usa.
  final int index;
  final Rect box;

  /// Ojo, ojo, nariz, comisura, comisura (orden de YuNet).
  final List<Offset> landmarks;
  final double score;

  double get roll => FaceCaptureQuality.rollFrom(landmarks[0], landmarks[1]);
  double get yaw =>
      FaceCaptureQuality.yawFrom(landmarks[0], landmarks[1], landmarks[2]);
}
