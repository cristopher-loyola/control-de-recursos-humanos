import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/attendance/attendance_review_store.dart';
import 'package:kiosk/attendance/attendance_store.dart';
import 'package:kiosk/attendance/pin_store.dart';
import 'package:kiosk/audit/audit_store.dart';
import 'package:kiosk/backup/backup_service.dart';
import 'package:kiosk/backup/backup_snapshot.dart';
import 'package:kiosk/database/local_database.dart';
import 'package:kiosk/employees/employee_store.dart';
import 'package:kiosk/vision/face_engine.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Cifrado de prueba: invierte los bytes y exige el mismo contexto al abrir.
class ReversingCipher implements TemplateCipher {
  @override
  Future<Uint8List> seal(Uint8List bytes, String context) async =>
      Uint8List.fromList([...utf8.encode('$context|'), ...bytes.reversed]);

  @override
  Future<Uint8List> unseal(Uint8List bytes, String context) async {
    final prefix = utf8.encode('$context|');
    if (bytes.length < prefix.length ||
        utf8.decode(bytes.sublist(0, prefix.length)) != '$context|') {
      throw StateError('Contexto distinto');
    }
    return Uint8List.fromList(bytes.sublist(prefix.length).reversed.toList());
  }
}

void main() {
  sqfliteFfiInit();
  late Directory temp;
  late LocalDatabase database;
  late PinStore pins;
  late AttendanceStore attendance;
  late AttendanceReviewStore reviews;
  late DateTime now;
  final cipher = ReversingCipher();
  final photo = Uint8List.fromList([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);

  setUp(() async {
    now = DateTime(2026, 11, 5, 8, 30);
    temp = await Directory.systemTemp.createTemp('rh_pin_');
    database = LocalDatabase(
      filePath: path.join(temp.path, 'test.db'),
      factory: databaseFactoryFfi,
    );
    await EmployeeStore(
      database: database,
      authorize: () {},
    ).add('7', 'Rosa Díaz');
    pins = PinStore(
      database,
      authorizeAssign: () {},
      actor: () => 'responsable_rh',
      clock: () => now,
    );
    attendance = AttendanceStore(
      database,
      // El checador con PIN no requiere sesión administrativa.
      authorizeRecord: () => throw StateError('Sin sesión'),
      photoCipher: cipher,
      clock: () => now,
    );
    reviews = AttendanceReviewStore(
      database,
      authorize: () {},
      actor: () => 'responsable_rh',
      photoCipher: cipher,
      clock: () => now,
    );
  });

  tearDown(() async {
    await database.close();
    await temp.delete(recursive: true);
  });

  test('Rechaza PIN obvios y genera PIN válidos', () {
    expect(PinStore.validate('123'), isNotNull);
    expect(PinStore.validate('1234'), isNotNull);
    expect(PinStore.validate('4321'), isNotNull);
    expect(PinStore.validate('0000'), isNotNull);
    expect(PinStore.validate('12a4'), isNotNull);
    expect(PinStore.validate('4827'), isNull);
    expect(PinStore.validate('482713'), isNull);
    for (var i = 0; i < 50; i++) {
      expect(PinStore.validate(PinStore.generate()), isNull);
    }
  });

  test('Solo se guarda el hash y el cambio queda en la bitácora', () async {
    await pins.assign('7', '4827');
    final db = await database.open();
    final row = (await db.query('employee_pins')).single;
    expect(
      utf8.decode(row['pin_hash'] as List<int>, allowMalformed: true),
      isNot(contains('4827')),
    );
    expect(await pins.withPin(), {'7'});
    final audit = await AuditStore(database, authorize: () {}).list();
    expect(audit.first.action, AuditAction.pinAssigned);
    await pins.assign('7', null);
    expect(await pins.withPin(), isEmpty);
  });

  test('La checada con PIN guarda foto cifrada y queda pendiente', () async {
    await pins.assign('7', '4827');
    final check = await pins.verify('7', '4827');
    expect(check.employeeName, 'Rosa Díaz');
    await attendance.recordPin(check, AttendanceKind.entry, photo: photo);

    final db = await database.open();
    final stored = (await db.query('attendance_photos')).single;
    expect(stored['encrypted_jpeg'], isNot(photo));

    final item = (await reviews.forDay(now)).single;
    expect(item.captureMethod, 'pin');
    expect(item.decision, isNull);
    expect(item.hasPhoto, isTrue);
    expect(item.scheduleNote, contains('Checada con PIN'));
    expect(await reviews.photo(item.eventId), photo);

    // El mismo PIN comprobado no sirve para una segunda checada.
    await expectLater(
      attendance.recordPin(check, AttendanceKind.exit),
      throwsA(isA<PinRuleError>()),
    );
  });

  test('Sin foto la checada se guarda y se avisa a RH', () async {
    await pins.assign('7', '4827');
    await attendance.recordPin(
      await pins.verify('7', '4827'),
      AttendanceKind.entry,
    );
    final item = (await reviews.forDay(now)).single;
    expect(item.hasPhoto, isFalse);
    expect(item.scheduleNote, contains('Sin foto'));
  });

  test('El PIN caduca si no se elige entrada o salida a tiempo', () async {
    await pins.assign('7', '4827');
    final check = await pins.verify('7', '4827');
    now = now.add(const Duration(seconds: 30));
    await expectLater(
      attendance.recordPin(check, AttendanceKind.entry, photo: photo),
      throwsA(isA<PinRuleError>()),
    );
  });

  test(
    'No revela si falló el número o el PIN y bloquea tras 5 intentos',
    () async {
      await pins.assign('7', '4827');
      Future<String> attempt(String number, String pin) async {
        try {
          await pins.verify(number, pin);
          return 'ok';
        } on PinRuleError catch (error) {
          return error.message;
        }
      }

      final unknown = await attempt('99', '4827');
      final wrong = await attempt('7', '1111');
      expect(unknown, wrong);
      for (var i = 0; i < 3; i++) {
        await attempt('7', '1111');
      }
      expect(await attempt('7', '1111'), contains('bloqueado'));
      // Bloqueado, ni el PIN correcto entra.
      expect(await attempt('7', '4827'), contains('bloqueado'));
      now = now.add(const Duration(minutes: 16));
      expect(await attempt('7', '4827'), 'ok');
      final audit = await AuditStore(database, authorize: () {}).list();
      expect(audit.any((e) => e.action == AuditAction.pinLocked), isTrue);
    },
  );

  test('El respaldo acepta checadas con PIN y omite fotos y PIN', () async {
    await pins.assign('7', '4827');
    await attendance.recordPin(
      await pins.verify('7', '4827'),
      AttendanceKind.entry,
      photo: photo,
    );
    final backups = BackupService(database, authorize: () {});
    final snapshot = BackupSnapshot.decode((await backups.capture()).encode());
    expect(snapshot.events.single['capture_method'], 'pin');
    await backups.restore(snapshot);
    final db = await database.open();
    expect(await db.query('attendance_events'), hasLength(1));
    expect(await db.query('attendance_photos'), isEmpty);
    expect(await db.query('employee_pins'), isEmpty);
  });
}
