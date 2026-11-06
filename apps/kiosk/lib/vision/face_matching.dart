import 'dart:math';

class FaceRuleError implements Exception {
  const FaceRuleError(this.message);
  final String message;
}

/// El rostro no alcanzó la confianza necesaria; se puede volver a intentar.
class FaceNotRecognized extends FaceRuleError {
  const FaceNotRecognized()
    : super(
        'No pude identificarte con suficiente confianza. Repite la toma o solicita apoyo a RH.',
      );
}

class FaceMatching {
  // Conservative pilot thresholds. Must be evaluated on the target tablet/population.
  // Sobre el promedio de las tomas. OpenCV recomienda 0.363 para SFace; se deja margen.
  static const threshold = 0.45;
  static const margin = 0.08;
  static const dimensions = 128;
  static const sampleCount = 3;

  /// Tomas que guarda cada rostro: las 3 del registro y las que aprende al
  /// checar con alta confianza, para adaptarse a la luz y a cambios de aspecto.
  static const maxGallery = 15;

  /// Solo se aprende de identificaciones muy claras.
  static const learnThreshold = 0.55;

  static List<double> normalize(List<double> vector) {
    if (vector.length != dimensions || vector.any((v) => !v.isFinite)) {
      throw const FaceRuleError('La muestra facial no es válida.');
    }
    final norm = sqrt(vector.fold<double>(0, (sum, v) => sum + v * v));
    if (!norm.isFinite || norm < 0.000001) {
      throw const FaceRuleError('No se pudo leer el rostro. Repite la toma.');
    }
    return vector.map((v) => v / norm).toList(growable: false);
  }

  static double cosine(List<double> a, List<double> b) {
    var sum = 0.0;
    for (var i = 0; i < dimensions; i++) {
      sum += a[i] * b[i];
    }
    return sum.clamp(-1.0, 1.0);
  }

  static List<List<double>> samples(List<List<double>> values) {
    if (values.length != sampleCount) {
      throw const FaceRuleError('Se necesitan tres muestras del mismo rostro.');
    }
    final normalized = values.map(normalize).toList(growable: false);
    for (var i = 0; i < normalized.length; i++) {
      for (var j = i + 1; j < normalized.length; j++) {
        if (cosine(normalized[i], normalized[j]) < 0.60) {
          throw const FaceRuleError(
            'El rostro cambió durante la toma. Repite el intento.',
          );
        }
      }
    }
    return normalized;
  }

  /// Galería guardada: de 3 a [maxGallery] tomas normalizadas.
  static List<List<double>> gallery(List<List<double>> values) {
    if (values.length < sampleCount || values.length > maxGallery) {
      throw const FaceRuleError('La plantilla facial no es válida.');
    }
    return values.map(normalize).toList(growable: false);
  }

  /// Agrega a la galería las tomas que aportan algo nuevo. Las del registro
  /// (las primeras [sampleCount]) nunca se reemplazan; si no cabe, sale la
  /// aprendida más antigua. Devuelve null si no hubo cambios.
  static List<List<double>>? learn(
    List<List<double>> gallery,
    List<List<double>> query,
  ) {
    final updated = [...gallery];
    var changed = false;
    for (final sample in query) {
      if (updated.any((other) => cosine(other, sample) > 0.95)) continue;
      updated.add(sample);
      changed = true;
    }
    if (!changed) return null;
    while (updated.length > maxGallery) {
      updated.removeAt(sampleCount);
    }
    return updated;
  }

  /// Promedio de la mejor coincidencia de cada toma: una toma borrosa no
  /// tumba la identificación, pero todas cuentan.
  static double score(List<List<double>> query, List<List<double>> enrolled) =>
      query
          .map(
            (sample) =>
                enrolled.map((other) => cosine(sample, other)).reduce(max),
          )
          .reduce((a, b) => a + b) /
      query.length;
}
