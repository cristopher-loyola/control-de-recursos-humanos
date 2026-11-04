import 'dart:math';

class FaceRuleError implements Exception {
  const FaceRuleError(this.message);
  final String message;
}

class FaceMatching {
  // Conservative pilot thresholds. Must be evaluated on the target tablet/population.
  // Sobre el promedio de las tomas. OpenCV recomienda 0.363 para SFace; se deja margen.
  static const threshold = 0.45;
  static const margin = 0.08;
  static const dimensions = 128;
  static const sampleCount = 3;

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
