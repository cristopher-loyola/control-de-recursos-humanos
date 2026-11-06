import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/vision/face_matching.dart';

/// Vector unitario entre los ejes 0 y 1, a [degrees] grados del eje 0.
List<double> at(double degrees) {
  final radians = degrees * pi / 180;
  return List.generate(
    FaceMatching.dimensions,
    (i) => i == 0
        ? cos(radians)
        : i == 1
        ? sin(radians)
        : 0.0,
  );
}

/// Vector unitario sobre un solo eje: distinto de todos los demás.
List<double> axis(int index) =>
    List.generate(FaceMatching.dimensions, (i) => i == index ? 1.0 : 0.0);

void main() {
  test('Aprende solo tomas nuevas y conserva las del registro', () {
    final enrolled = [at(0), at(1), at(2)];
    // Casi idéntica a una existente: no aporta nada.
    expect(FaceMatching.learn(enrolled, [at(1.5)]), isNull);

    // De dos tomas casi iguales solo entra una.
    var gallery = FaceMatching.learn(enrolled, [at(30), at(31), at(60)])!;
    expect(gallery, hasLength(5));
    expect(gallery.take(3), enrolled);

    for (var step = 0; step < 20; step++) {
      gallery = FaceMatching.learn(gallery, [axis(10 + step)])!;
    }
    expect(gallery, hasLength(FaceMatching.maxGallery));
    // Las tomas del registro nunca salen; sale la aprendida más antigua.
    expect(gallery.take(3), enrolled);
    expect(gallery.last, axis(29));
    // 3 del registro + las 12 aprendidas más recientes (ejes 18 a 29).
    expect(gallery[3], axis(18));
  });

  test('La galería acepta de 3 a 15 tomas', () {
    expect(
      () => FaceMatching.gallery([at(0), at(1)]),
      throwsA(isA<FaceRuleError>()),
    );
    expect(
      FaceMatching.gallery([for (var i = 0; i < 15; i++) at(i * 5.0)]),
      hasLength(15),
    );
    expect(
      () => FaceMatching.gallery([for (var i = 0; i < 16; i++) at(i * 5.0)]),
      throwsA(isA<FaceRuleError>()),
    );
  });

  test('Más tomas aprendidas suben la coincidencia con una luz distinta', () {
    final enrolled = [at(0), at(2), at(4)];
    final otherLight = [at(60), at(61), at(62)];
    final before = FaceMatching.score(otherLight, enrolled);
    final learned = FaceMatching.learn(enrolled, [at(55), at(58)])!;
    expect(FaceMatching.score(otherLight, learned), greaterThan(before));
  });
}
