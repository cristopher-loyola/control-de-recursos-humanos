import 'dart:math';
import 'dart:ui';

/// Revisa encuadre; no verifica identidad ni prueba de vida.
class FaceCaptureQuality {
  /// Retry upside-down metadata; never treat an inverted face as upright.
  static int? uprightRetry(int rotation, double? roll) =>
      roll != null && roll.isFinite && roll.abs() > 120
      ? (rotation + 180) % 360
      : null;

  /// Keeps the largest face plus any of comparable size (a real second person).
  /// Small detections are background noise and must not block the capture.
  static List<T> people<T>(List<T> faces, Rect Function(T) bounds) {
    if (faces.length < 2) return faces;
    double area(T face) => bounds(face).width * bounds(face).height;
    final sorted = [...faces]..sort((a, b) => area(b).compareTo(area(a)));
    final largest = area(sorted.first);
    return sorted.where((face) => area(face) >= largest * 0.5).toList();
  }

  /// Inclinación hacia los hombros, en grados, según la línea entre los ojos.
  static double rollFrom(Offset eyeA, Offset eyeB) {
    final (left, right) = eyeA.dx <= eyeB.dx ? (eyeA, eyeB) : (eyeB, eyeA);
    return atan2(right.dy - left.dy, right.dx - left.dx) * 180 / pi;
  }

  /// Giro aproximado, en grados: desplazamiento de la nariz respecto al centro
  /// de los ojos. La nariz sobresale cerca de 0.6 veces la distancia entre ojos.
  static double yawFrom(Offset eyeA, Offset eyeB, Offset nose) {
    final distance = (eyeB - eyeA).distance;
    if (distance < 1) return double.nan;
    final middle = Offset((eyeA.dx + eyeB.dx) / 2, (eyeA.dy + eyeB.dy) / 2);
    return atan((nose.dx - middle.dx) / distance / 0.6) * 180 / pi;
  }

  static String? issue({
    required int faceCount,
    Rect? faceBounds,
    required Size imageSize,
    double? headRoll,
    double? headYaw,
    double maxYaw = 20,
  }) {
    if (faceCount == 0) return 'Coloca tu rostro frente a la cámara.';
    if (faceCount != 1) return 'Debe aparecer una sola persona.';
    if (faceBounds == null || imageSize.isEmpty) {
      return 'No se pudo medir el rostro.';
    }
    final width = faceBounds.width / imageSize.width;
    final height = faceBounds.height / imageSize.height;
    // SFace alinea y recorta a 112x112; con ~100 px de rostro alcanza.
    if (width < 0.15 || height < 0.15) {
      return 'Acércate un poco a la cámara.';
    }
    if (faceBounds.left < 0 ||
        faceBounds.top < 0 ||
        faceBounds.right > imageSize.width ||
        faceBounds.bottom > imageSize.height) {
      return 'Muestra el rostro completo dentro del cuadro.';
    }
    final center = faceBounds.center;
    if ((center.dx / imageSize.width - 0.5).abs() > 0.3 ||
        (center.dy / imageSize.height - 0.5).abs() > 0.3) {
      return 'Centra tu rostro en la cámara.';
    }
    if ((headRoll?.abs() ?? 0) > 20) {
      return 'Endereza la cabeza, sin inclinarla hacia los hombros.';
    }
    if ((headYaw?.abs() ?? 0) > maxYaw) {
      return 'Gira menos la cabeza; mantén ambos ojos visibles.';
    }
    return null;
  }
}
