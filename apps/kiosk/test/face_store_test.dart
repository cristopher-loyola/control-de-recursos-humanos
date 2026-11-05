import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/attendance/attendance_store.dart';
import 'package:kiosk/backup/backup_service.dart';
import 'package:kiosk/backup/backup_snapshot.dart';
import 'package:kiosk/database/local_database.dart';
import 'package:kiosk/departments/department_store.dart';
import 'package:kiosk/reports/report_store.dart';
import 'package:kiosk/holidays/holiday_store.dart';
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
      // Esquema v9: empleados sin departamento y sin tabla de departamentos.
      await db.execute('PRAGMA foreign_keys = OFF');
      await db.execute('''
        CREATE TABLE employees_v9 (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          number TEXT NOT NULL UNIQUE CHECK(length(trim(number)) BETWEEN 1 AND 30),
          name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 120)
        )
      ''');
      await db.execute(
        'INSERT INTO employees_v9 (id, number, name) SELECT id, number, name FROM employees',
      );
      await db.execute('DROP TABLE employees');
      await db.execute('ALTER TABLE employees_v9 RENAME TO employees');
      await db.execute('DROP TABLE holidays');
      await db.execute('DROP TABLE departments');
      await db.execute('PRAGMA foreign_keys = ON');
      for (final column in [
        'capture_method',
        'similarity',
        'identity_model',
        'liveness_method',
        'schedule_note',
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
      expect(rows.first['liveness_method'], 'none');
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

  test('A tiempo se aprueba sola; retardo, sin departamento y manual van a revisión', () async {
    final departments = DepartmentStore(
      database,
      authorize: authorize,
      actor: () => 'test-admin',
    );
    await departments.save(
      name: 'Producción',
      entryMinutes: 8 * 60,
      exitMinutes: 17 * 60,
      toleranceMinutes: 10,
    );
    final production = (await departments.list()).single;
    await employees.setDepartment('001', production.id);
    await enroll('001', 0);
    await enroll('002', 1);
    final db = await database.open();
    Future<Map<String, Object?>> last() async => (await db.rawQuery('''
      SELECT a.schedule_note, r.decision, r.reviewer FROM attendance_events a
      LEFT JOIN attendance_reviews r ON r.event_id = a.id ORDER BY a.id DESC LIMIT 1
    ''')).single;

    now = DateTime(2026, 10, 31, 8, 9);
    await attendance.recordFacial(
      await faces.identify(samples(0)),
      AttendanceKind.entry,
    );
    expect(await last(), {
      'schedule_note': null,
      'decision': 'approved',
      'reviewer': 'sistema',
    });

    now = DateTime(2026, 10, 31, 16, 30);
    await attendance.recordFacial(
      await faces.identify(samples(0)),
      AttendanceKind.exit,
    );
    expect((await last())['decision'], isNull);
    expect(
      (await last())['schedule_note'],
      contains('Salida anticipada por 30 min'),
    );

    await attendance.recordFacial(
      await faces.identify(samples(1)),
      AttendanceKind.entry,
    );
    expect((await last())['decision'], isNull);
    expect((await last())['schedule_note'], contains('Sin departamento'));

    now = DateTime(2026, 11, 1, 8);
    await attendance.record('001', AttendanceKind.entry);
    expect(
      (await last())['decision'],
      isNull,
      reason: 'Las manuales siempre las revisa RH.',
    );

    expect(
      (await employees.list())
          .firstWhere((e) => e.number == '001')
          .departmentName,
      'Producción',
    );
  });

  test('El número de empleado es consecutivo y lo asigna el sistema', () async {
    expect(await employees.register('Carla Ruiz'), '3');
    expect(await employees.register('Diego Mora'), '4');
    final numbers = (await employees.list()).map((e) => e.number).toSet();
    expect(numbers, containsAll(['001', '002', '3', '4']));
  });

  test(
    'El tablero excluye checadas rechazadas y filtra por departamento',
    () async {
      final departments = DepartmentStore(database, authorize: authorize);
      await departments.save(
        name: 'Almacén',
        entryMinutes: 8 * 60,
        exitMinutes: 17 * 60,
        toleranceMinutes: 10,
      );
      final almacen = (await departments.list()).single;
      expect(almacen.workDays, 31);
      await employees.setDepartment('001', almacen.id);
      final db = await database.open();
      await db.update('employees', {
        'registered_at': DateTime(2026, 10, 1).toUtc().millisecondsSinceEpoch,
      });
      await attendance.record('001', AttendanceKind.entry);
      final reports = ReportStore(
        database,
        authorize: authorize,
        clock: () => DateTime(2026, 10, 31, 18),
      );
      // 31 de octubre de 2026 es sábado: día de descanso para lunes a viernes.
      var data = await reports.load(
        start: DateTime(2026, 10, 26),
        end: DateTime(2026, 11, 2),
      );
      final ana = data.summaries.firstWhere((s) => s.employee.number == '001');
      expect(ana.workDays, 5);
      expect(ana.absent, 5);
      expect(
        data.pendingReviews,
        1,
        reason: 'La checada manual queda por revisar.',
      );

      data = await reports.load(
        start: DateTime(2026, 10, 26),
        end: DateTime(2026, 11, 2),
        departmentId: almacen.id,
      );
      expect(data.summaries.map((s) => s.employee.number), ['001']);
      data = await reports.load(
        start: DateTime(2026, 10, 26),
        end: DateTime(2026, 11, 2),
        withoutDepartment: true,
      );
      expect(data.summaries.map((s) => s.employee.number), ['002']);
    },
  );

  test('Festivos oficiales, sin duplicados y con bitácora', () async {
    expect(officialHolidays(2026).map((h) => formatDay(h.day)), [
      '2026-01-01',
      '2026-02-02',
      '2026-03-16',
      '2026-05-01',
      '2026-09-16',
      '2026-11-16',
      '2026-12-25',
    ]);
    expect(
      officialHolidays(2030).any((h) => h.day == DateTime(2030, 10, 1)),
      isTrue,
    );
    final store = HolidayStore(
      database,
      authorize: authorize,
      actor: () => 'test-admin',
    );
    expect(await store.addOfficial(2026), 7);
    expect(await store.addOfficial(2026), 0);
    await expectLater(
      store.add(day: DateTime(2026, 12, 25), name: 'Otra vez'),
      throwsA(isA<HolidayRuleError>()),
    );
    await store.add(day: DateTime(2026, 12, 24), name: 'Nochebuena');
    final december = await store.list(
      from: DateTime(2026, 12),
      to: DateTime(2027),
    );
    expect(december.map((h) => h.name), ['Nochebuena', 'Navidad']);
    await store.remove(december.first.id);
    expect(
      await store.list(from: DateTime(2026, 12), to: DateTime(2027)),
      hasLength(1),
    );
    final audit = await (await database.open()).query(
      'audit_entries',
      where: "action LIKE 'holiday_%'",
    );
    expect(audit, hasLength(9));
    staff = false;
    await expectLater(
      store.add(day: DateTime(2026, 12, 31), name: 'Fin de año'),
      throwsStateError,
    );
  });
}
