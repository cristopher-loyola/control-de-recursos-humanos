import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kiosk/vision/face_engine.dart';
import 'package:kiosk/vision/face_matching.dart';
import 'package:kiosk/vision/face_template_store.dart';
import 'package:kiosk/vision/consent_store.dart';
import 'package:kiosk/database/local_database.dart';
import 'package:kiosk/employees/employee_store.dart';
import 'package:kiosk/attendance/attendance_store.dart';

import 'face_fixtures.dart';

Future<List<double>> embedding(
  String fixture, {
  double brightness = 1,
  bool upsideDown = false,
}) async {
  final codec = await ui.instantiateImageCodec(base64Decode(fixture));
  final image = (await codec.getNextFrame()).image;
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
      .buffer
      .asUint8List();
  final width = image.width ~/ 2 * 2;
  final height = image.height ~/ 2 * 2;
  final nv21 = Uint8List(width * height * 3 ~/ 2);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final offset = upsideDown
          ? ((height - 1 - y) * image.width + width - 1 - x) * 4
          : (y * image.width + x) * 4;
      final r = (rgba[offset] * brightness).round().clamp(0, 255);
      final g = (rgba[offset + 1] * brightness).round().clamp(0, 255);
      final b = (rgba[offset + 2] * brightness).round().clamp(0, 255);
      nv21[y * width + x] = ((66 * r + 129 * g + 25 * b + 128) ~/ 256 + 16)
          .clamp(0, 255);
      if (y.isEven && x.isEven) {
        final uv = width * height + (y ~/ 2) * width + x;
        nv21[uv] = ((112 * r - 94 * g - 18 * b + 128) ~/ 256 + 128).clamp(
          0,
          255,
        );
        nv21[uv + 1] = ((-38 * r - 74 * g + 112 * b + 128) ~/ 256 + 128).clamp(
          0,
          255,
        );
      }
    }
  }
  image.dispose();
  codec.dispose();
  final detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      enableLandmarks: true,
      minFaceSize: .02,
    ),
  );
  try {
    final faces = await detector.processImage(
      InputImage.fromBytes(
        bytes: nv21,
        metadata: InputImageMetadata(
          size: ui.Size(width.toDouble(), height.toDouble()),
          rotation: upsideDown
              ? InputImageRotation.rotation180deg
              : InputImageRotation.rotation0deg,
          format: InputImageFormat.nv21,
          bytesPerRow: width,
        ),
      ),
    );
    expect(
      faces,
      isNotEmpty,
      reason: 'La imagen de prueba debe contener un rostro detectable.',
    );
    faces.sort(
      (a, b) => (b.boundingBox.width * b.boundingBox.height).compareTo(
        a.boundingBox.width * a.boundingBox.height,
      ),
    );
    final face = faces.first;
    final eyes = [
      face.landmarks[FaceLandmarkType.leftEye]!.position,
      face.landmarks[FaceLandmarkType.rightEye]!.position,
    ]..sort((a, b) => a.x.compareTo(b.x));
    final mouth = [
      face.landmarks[FaceLandmarkType.leftMouth]!.position,
      face.landmarks[FaceLandmarkType.rightMouth]!.position,
    ]..sort((a, b) => a.x.compareTo(b.x));
    final points = [
      eyes[0],
      eyes[1],
      face.landmarks[FaceLandmarkType.noseBase]!.position,
      mouth[0],
      mouth[1],
    ];
    return await FaceEngine().extract(
      bytes: nv21,
      width: width,
      height: height,
      rotation: upsideDown ? 180 : 0,
      landmarks: points
          .expand((p) => [p.x.toDouble(), p.y.toDouble()])
          .toList(),
    );
  } finally {
    await detector.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SFace nativo: mismo rostro con distinta luz y otra identidad', (
    tester,
  ) async {
    expect(
      fixtureA,
      isNotEmpty,
      reason: 'Las imágenes de prueba deben estar disponibles.',
    );
    expect(fixtureB, isNotEmpty);
    await FaceEngine().initialize();
    final first = await embedding(fixtureA);
    final dimmed = await embedding(fixtureA, brightness: .8);
    final other = await embedding(fixtureB);
    final turned = await embedding(fixtureA, upsideDown: true);
    expect(
      FaceMatching.cosine(first, turned),
      greaterThanOrEqualTo(FaceMatching.threshold),
    );
    expect(first, hasLength(128));
    expect(
      sqrt(first.fold<double>(0, (sum, v) => sum + v * v)),
      closeTo(1, .0001),
    );
    expect(
      FaceMatching.cosine(first, dimmed),
      greaterThanOrEqualTo(FaceMatching.threshold),
    );
    expect(FaceMatching.cosine(first, other), lessThan(FaceMatching.threshold));
  });

  testWidgets(
    'Rostro real: identifica el ID guardado, persiste cifrado y registra asistencia',
    (tester) async {
      final temp = await Directory.systemTemp.createTemp('face-integration-');
      final database = LocalDatabase(filePath: '${temp.path}/test.db');
      try {
        final employees = EmployeeStore(database: database, authorize: () {});
        final consents = ConsentStore(
          database,
          authorize: () {},
          actor: () => 'integration-test',
        );
        final faces = FaceTemplateStore(
          database,
          cipher: FaceEngine(),
          authorizeEnrollment: () {},
          actor: () => 'integration-test',
        );
        final a = await embedding(fixtureA);
        final b = await embedding(fixtureB);
        final changedLight = await embedding(fixtureA, brightness: .8);
        for (final number in ['900001', '900002']) {
          await employees.add(
            number,
            number == '900001' ? 'Persona Uno' : 'Persona Dos',
          );
          await consents.record(
            number,
            ConsentKind.recorded,
            'FIXTURE-ONLY-$number',
          );
        }
        await faces.enroll('900001', [a, a, a]);
        await faces.enroll('900002', [b, b, b]);
        await database.close();
        final match = await faces.identify([
          changedLight,
          changedLight,
          changedLight,
        ]);
        expect(match.employeeNumber, '900001');
        final attendance = AttendanceStore(
          database,
          authorizeRecord: () => throw StateError('No staff session'),
        );
        await attendance.recordFacial(match, AttendanceKind.entry);
        expect(
          (await attendance.lastFor('900001'))!.kind,
          AttendanceKind.entry,
        );
        expect(await attendance.lastFor('900002'), isNull);
        final row = (await (await database.open()).query(
          'face_templates',
          where: 'employee_number = ?',
          whereArgs: ['900001'],
        )).single;
        expect(row['encrypted_template'], isA<Uint8List>());
        expect(row.containsKey('image'), isFalse);
      } finally {
        await database.close();
        await temp.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'Keystore: cifrado autenticado rechaza otro empleado y alteraciones',
    (tester) async {
      final engine = FaceEngine();
      final plain = Uint8List.fromList(
        utf8.encode('test-template-no-real-person'),
      );
      final sealed = await engine.seal(plain, 'integration-test-001');
      expect(sealed, isNot(orderedEquals(plain)));
      expect(
        await engine.unseal(sealed, 'integration-test-001'),
        orderedEquals(plain),
      );
      await expectLater(
        engine.unseal(sealed, 'integration-test-002'),
        throwsA(anything),
      );
      final tampered = Uint8List.fromList(sealed);
      tampered[tampered.length - 1] ^= 1;
      await expectLater(
        engine.unseal(tampered, 'integration-test-001'),
        throwsA(anything),
      );
    },
  );
}
