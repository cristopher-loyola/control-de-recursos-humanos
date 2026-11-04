import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/attendance/attendance_store.dart';
import 'package:kiosk/backup/backup_service.dart';
import 'package:kiosk/backup/backup_snapshot.dart';
import 'package:kiosk/database/local_database.dart';
import 'package:kiosk/employees/employee_store.dart';
import 'package:kiosk/vision/consent_store.dart';
import 'package:kiosk/vision/face_engine.dart';
import 'package:kiosk/vision/face_matching.dart';
import 'package:kiosk/vision/face_template_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// In-memory fake for storage tests only. Android AES-GCM is tested on-device.
class TestCipher implements TemplateCipher {
  final _values = <String, Uint8List>{};
  int unsealCalls = 0;
  @override
  Future<Uint8List> seal(Uint8List bytes, String context) async {
    _values[context] = Uint8List.fromList(bytes);
    return Uint8List.fromList(utf8.encode(context));
  }

  @override
  Future<Uint8List> unseal(Uint8List bytes, String context) async {
    unsealCalls++;
    if (utf8.decode(bytes) != context) throw StateError('Wrong context');
    return _values[context]!;
  }
}

List<List<double>> samples(int axis) =>
    List.generate(3, (_) => List.generate(128, (i) => i == axis ? 1.0 : 0.0));

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late LocalDatabase database;
  late EmployeeStore employees;
  late ConsentStore consents;
  late FaceTemplateStore faces;
  late AttendanceStore attendance;
  late DateTime now;
  var staff = true;
  void authorize() {
    if (!staff) throw StateError('Access denied');
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('rh_faces_');
    database = LocalDatabase(
      filePath: '${temp.path}/faces.db',
      factory: databaseFactoryFfi,
    );
    staff = true;
    now = DateTime(2026, 10, 31, 8);
    employees = EmployeeStore(database: database, authorize: authorize);
    consents = ConsentStore(
      database,
      authorize: authorize,
      actor: () => 'test-admin',
    );
    faces = FaceTemplateStore(
      database,
      cipher: TestCipher(),
      authorizeEnrollment: authorize,
      actor: () => 'test-admin',
      clock: () => now,
    );
    attendance = AttendanceStore(
      database,
      authorizeRecord: authorize,
      clock: () => now,
    );
    await employees.add('001', 'Ana Pérez');
    await employees.add('002', 'Luis López');
  });
  tearDown(() async {
    await database.close();
    await temp.delete(recursive: true);
  });

  Future<void> enroll(String number, int axis) async {
    await consents.record(number, ConsentKind.recorded, 'TEST-CONSENT-$number');
    await faces.enroll(number, samples(axis));
  }

  test(
    'Migrar la base v9 conserva empleados, consentimientos y checadas',
    () async {
      await consents.record('001', ConsentKind.recorded, 'TEST-CONSENT-001');
      await attendance.record('001', AttendanceKind.entry);
      final db = await database.open();
      await db.execute('DROP TABLE face_templates');
      for (final column in [
        'capture_method',
        'similarity',
        'identity_model',
        'liveness_method',
      ]) {
        await db.execute('ALTER TABLE attendance_events DROP COLUMN $column');
      }
      await db.setVersion(9);
      await database.close();
      expect(await employees.list(), hasLength(2));
      expect((await attendance.lastFor('001'))!.kind, AttendanceKind.entry);
      expect((await consents.requireActiveConsent('001')).active, isTrue);
      await faces.enroll('001', samples(0));
      expect((await faces.identify(samples(0))).employeeNumber, '001');
      expect(
        (await (await database.open()).query('attendance_events'))
            .single['capture_method'],
        'manual',
      );
    },
  );

  test(
    'Exige permiso y consentimiento; asocia rostro al ID y persiste al reabrir',
    () async {
      await expectLater(
        faces.enroll('001', samples(0)),
        throwsA(isA<FaceRuleError>()),
      );
      await consents.record('001', ConsentKind.recorded, 'TEST-CONSENT-001');
      staff = false;
      await expectLater(faces.enroll('001', samples(0)), throwsStateError);
      staff = true;
      await faces.enroll('001', samples(0));
      await enroll('002', 1);
      await database.close();
      expect((await faces.identify(samples(1))).employeeNumber, '002');
      expect((await faces.identify(samples(0))).employeeName, 'Ana Pérez');
      expect((await employees.list()).every((e) => e.hasFace), isTrue);
      await expectLater(
        faces.identify(samples(2)),
        throwsA(isA<FaceRuleError>()),
      );
    },
  );

  test('Impide asociar el mismo rostro a otro trabajador', () async {
    await enroll('001', 0);
    await consents.record('002', ConsentKind.recorded, 'TEST-CONSENT-002');
    await expectLater(
      faces.enroll('002', samples(0)),
      throwsA(isA<FaceRuleError>()),
    );
    expect((await faces.identify(samples(0))).employeeNumber, '001');
  });

  test('Rechaza coincidencias ambiguas entre trabajadores', () async {
    await enroll('001', 0);
    await enroll('002', 1);
    final ambiguous = samples(0);
    for (final vector in ambiguous) {
      vector[1] = 1;
    }
    await expectLater(faces.identify(ambiguous), throwsA(isA<FaceRuleError>()));
  });

  test(
    'Checada facial sin sesión, comprobante de un uso y límite diario',
    () async {
      await enroll('001', 0);
      staff = false;
      await expectLater(
        attendance.record('001', AttendanceKind.entry),
        throwsStateError,
      );
      final match = await faces.identify(samples(0));
      await attendance.recordFacial(match, AttendanceKind.entry);
      await expectLater(
        attendance.recordFacial(match, AttendanceKind.exit),
        throwsA(isA<FaceRuleError>()),
      );
      now = now.add(const Duration(hours: 8));
      expect(await attendance.nextFor('001'), AttendanceKind.exit);
      await attendance.recordFacial(
        await faces.identify(samples(0)),
        AttendanceKind.exit,
      );
      expect(await attendance.nextFor('001'), isNull);
      await expectLater(
        attendance.recordFacial(
          await faces.identify(samples(0)),
          AttendanceKind.entry,
        ),
        throwsA(isA<AttendanceRuleError>()),
      );
      final rows = await (await database.open()).query('attendance_events');
      expect(rows, hasLength(2));
      expect(rows.first['capture_method'], 'facial');
      expect(rows.first['identity_model'], FaceEngine.modelId);
      expect(rows.first['liveness_method'], 'blink_challenge_v1');
    },
  );

  test('Caduca la identificación y la revocación impide usar un resultado anterior', () async {
    await enroll('001', 0);
    final expired = await faces.identify(samples(0));
    now = now.add(const Duration(seconds: 21));
    await expectLater(
      attendance.recordFacial(expired, AttendanceKind.entry),
      throwsA(isA<FaceRuleError>()),
    );
    final revoked = await faces.identify(samples(0));
    await consents.record('001', ConsentKind.revoked, 'TEST-REVOCATION-001');
    await expectLater(
      attendance.recordFacial(revoked, AttendanceKind.entry),
      throwsA(isA<FaceRuleError>()),
    );
    await expectLater(
      faces.identify(samples(0)),
      throwsA(isA<FaceRuleError>()),
    );
    expect(await attendance.forDay(now), isEmpty);
    expect(await (await database.open()).query('face_templates'), isEmpty);
  });

  test(
    'Respaldos preservan metadatos faciales y no borran rostros existentes',
    () async {
      await enroll('001', 0);
      await attendance.recordFacial(
        await faces.identify(samples(0)),
        AttendanceKind.entry,
      );
      final service = BackupService(database, authorize: authorize);
      final snapshot = await service.capture();
      final restored = BackupSnapshot.decode(snapshot.encode());
      expect(restored.events.single['capture_method'], 'facial');
      expect(restored.events.single['similarity'], closeTo(1, 0.00001));
      await expectLater(
        service.restore(restored),
        throwsA(isA<InvalidBackup>()),
      );
      expect((await faces.identify(samples(0))).employeeNumber, '001');
      expect(await attendance.forDay(now), hasLength(1));
    },
  );

  test('Reemplazar un rostro invalida la identificación previa', () async {
    await enroll('001', 0);
    final prior = await faces.identify(samples(0));
    await faces.enroll('001', samples(2));
    await expectLater(
      attendance.recordFacial(prior, AttendanceKind.entry),
      throwsA(isA<FaceRuleError>()),
    );
    expect((await faces.identify(samples(2))).employeeNumber, '001');
  });

  test(
    'Reutiliza plantillas descifradas y detecta altas y revocaciones',
    () async {
      final cipher = TestCipher();
      faces = FaceTemplateStore(
        database,
        cipher: cipher,
        authorizeEnrollment: authorize,
        actor: () => 'test-admin',
        clock: () => now,
      );
      await enroll('001', 0);
      expect((await faces.identify(samples(0))).employeeNumber, '001');
      expect(cipher.unsealCalls, 1);
      expect((await faces.identify(samples(0))).employeeNumber, '001');
      expect(cipher.unsealCalls, 1);

      await enroll('002', 1);
      final callsAfterEnrollment = cipher.unsealCalls;
      expect((await faces.identify(samples(1))).employeeNumber, '002');
      expect(cipher.unsealCalls, callsAfterEnrollment + 2);

      await consents.record('002', ConsentKind.revoked, 'TEST-REVOCATION-002');
      await expectLater(
        faces.identify(samples(1)),
        throwsA(isA<FaceRuleError>()),
      );
      expect((await faces.identify(samples(0))).employeeNumber, '001');
    },
  );

  test(
    'Muestras inválidas, infinitas o de personas diferentes se rechazan',
    () {
      expect(
        () =>
            FaceMatching.samples([samples(0)[0], samples(1)[0], samples(0)[0]]),
        throwsA(isA<FaceRuleError>()),
      );
      expect(
        () => FaceMatching.normalize(List.filled(128, 0)),
        throwsA(isA<FaceRuleError>()),
      );
      expect(
        () => FaceMatching.normalize(List.filled(128, double.infinity)),
        throwsA(isA<FaceRuleError>()),
      );
      expect(
        () => FaceMatching.normalize(List.filled(128, 1e308)),
        throwsA(isA<FaceRuleError>()),
      );
    },
  );

  test('Una toma borrosa no tumba la identificación, pero sí cuenta', () {
    List<double> axis(int i) => List.generate(128, (j) => j == i ? 1.0 : 0.0);
    List<double> blend(double same) => FaceMatching.normalize(
      List.generate(
        128,
        (j) => j == 0
            ? same
            : j == 1
            ? 1 - same
            : 0.0,
      ),
    );
    final enrolled = [axis(0)];
    final good = blend(0.9);
    final blurry = axis(1);
    final score = FaceMatching.score([good, good, blurry], enrolled);
    expect(score, greaterThan(FaceMatching.threshold));
    expect(score, lessThan(FaceMatching.cosine(good, axis(0))));
    expect(
      FaceMatching.score([blurry, blurry, good], enrolled),
      lessThan(FaceMatching.threshold),
    );
  });
}
