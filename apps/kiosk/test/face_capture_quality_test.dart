import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/vision/face_capture_quality.dart';

void main() {
  test('Retries inverted frames without accepting a tilted face', () {
    expect(FaceCaptureQuality.uprightRetry(0, 179), 180);
    expect(FaceCaptureQuality.uprightRetry(270, -175), 90);
    expect(FaceCaptureQuality.uprightRetry(90, 25), isNull);
    expect(FaceCaptureQuality.uprightRetry(0, null), isNull);
    expect(FaceCaptureQuality.uprightRetry(0, double.nan), isNull);
  });
  const image = Size(1000, 800);
  const centeredFace = Rect.fromLTWH(350, 230, 300, 340);

  test('Solo acepta un rostro completo, cercano y centrado', () {
    expect(
      FaceCaptureQuality.issue(
        faceCount: 1,
        faceBounds: centeredFace,
        imageSize: image,
        headRoll: 4,
        headYaw: -5,
      ),
      isNull,
    );
    expect(FaceCaptureQuality.issue(faceCount: 0, imageSize: image), isNotNull);
    expect(FaceCaptureQuality.issue(faceCount: 2, imageSize: image), isNotNull);
    expect(
      FaceCaptureQuality.issue(
        faceCount: 1,
        faceBounds: const Rect.fromLTWH(450, 350, 100, 100),
        imageSize: image,
      ),
      isNotNull,
    );
    expect(
      FaceCaptureQuality.issue(
        faceCount: 1,
        faceBounds: const Rect.fromLTWH(900, 230, 300, 340),
        imageSize: image,
      ),
      isNotNull,
    );
    expect(
      FaceCaptureQuality.issue(
        faceCount: 1,
        faceBounds: centeredFace,
        imageSize: image,
        headYaw: 35,
      ),
      isNotNull,
    );
  });

  test(
    'Ignores small background detections but keeps a real second person',
    () {
      const face = Rect.fromLTWH(300, 200, 300, 340);
      const noise = Rect.fromLTWH(20, 20, 60, 60);
      const person = Rect.fromLTWH(650, 220, 260, 300);
      Rect box(Rect r) => r;
      expect(FaceCaptureQuality.people([noise, face, noise], box), [face]);
      expect(FaceCaptureQuality.people([face, person], box), [face, person]);
      expect(FaceCaptureQuality.people(<Rect>[], box), isEmpty);
    },
  );

  test('Estimates roll and yaw from the five YuNet landmarks', () {
    const leftEye = Offset(100, 100);
    const rightEye = Offset(200, 100);
    expect(FaceCaptureQuality.rollFrom(rightEye, leftEye), closeTo(0, 0.01));
    expect(
      FaceCaptureQuality.rollFrom(leftEye, const Offset(200, 136)),
      closeTo(19.8, 0.1),
    );
    expect(
      FaceCaptureQuality.yawFrom(leftEye, rightEye, const Offset(150, 140)),
      closeTo(0, 0.01),
    );
    expect(
      FaceCaptureQuality.yawFrom(leftEye, rightEye, const Offset(180, 140)),
      greaterThan(20),
    );
    expect(
      FaceCaptureQuality.yawFrom(leftEye, leftEye, const Offset(150, 140)),
      isNaN,
    );
  });
}
