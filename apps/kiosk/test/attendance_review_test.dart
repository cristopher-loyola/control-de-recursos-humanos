import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/attendance/attendance_review_store.dart';
import 'package:kiosk/attendance/attendance_store.dart';
import 'package:kiosk/audit/audit_store.dart';
import 'package:kiosk/backup/backup_service.dart';
import 'package:kiosk/backup/backup_snapshot.dart';
import 'package:kiosk/database/local_database.dart';
import 'package:kiosk/employees/employee_store.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Directory temp;
  late LocalDatabase database;
  late EmployeeStore employees;
  late AttendanceStore attendance;
  late AttendanceReviewStore reviews;
  late BackupService backups;
  late AuditStore audit;
  var allowed = true;
  final day = DateTime(2026, 10, 30, 8);

  setUp(() async {
    allowed = true;
    temp = await Directory.systemTemp.createTemp('rh_attendance_review_');
    database = LocalDatabase(
      filePath: path.join(temp.path, 'test.db'),
      factory: databaseFactoryFfi,
    );
    employees = EmployeeStore(database: database, authorize: () {});
    attendance = AttendanceStore(
      database,
      authorizeRecord: () {},
      clock: () => day,
    );
    reviews = AttendanceReviewStore(
      database,
      authorize: () {
        if (!allowed) throw StateError('Sin permiso');
      },
      actor: () => 'responsable_rh',
      clock: () => day.add(const Duration(hours: 1)),
    );
    backups = BackupService(database, authorize: () {});
    audit = AuditStore(database, authorize: () {});
  });

  tearDown(() async {
    await database.close();
    await temp.delete(recursive: true);
  });

  test('RH revisa una checada sin alterar el movimiento original', () async {
    await employees.add('001', 'Ana Pérez');
    await attendance.record('001', AttendanceKind.entry);
    final pending = (await reviews.forDay(day)).single;
    expect(pending.decision, isNull);
    await reviews.review(
      pending.eventId,
      ReviewDecision.approved,
      'Verificada con el registro del supervisor.',
    );
    final reviewed = (await reviews.forDay(day)).single;
    expect(reviewed.decision, ReviewDecision.approved);
    expect(reviewed.reviewer, 'responsable_rh');
    expect(reviewed.reason, 'Verificada con el registro del supervisor.');
    expect(reviewed.reviewedAt, day.add(const Duration(hours: 1)).toUtc());
    expect((await attendance.forDay(day)).single.kind, AttendanceKind.entry);
    expect(
      (await audit.list()).any(
        (item) => item.action == AuditAction.attendanceReviewed,
      ),
      isTrue,
    );
    await expectLater(
      reviews.review(
        pending.eventId,
        ReviewDecision.rejected,
        'Otro motivo suficiente',
      ),
      throwsA(isA<ReviewRuleError>()),
    );
  });

  test('No permite revisar sin permiso ni motivo suficiente', () async {
    await employees.add('001', 'Ana Pérez');
    await attendance.record('001', AttendanceKind.entry);
    final eventId = (await reviews.forDay(day)).single.eventId;
    await expectLater(
      reviews.review(eventId, ReviewDecision.approved, 'breve'),
      throwsA(isA<ReviewRuleError>()),
    );
    allowed = false;
    await expectLater(reviews.forDay(day), throwsStateError);
    await expectLater(
      reviews.review(eventId, ReviewDecision.approved, 'Motivo suficiente'),
      throwsStateError,
    );
    allowed = true;
    expect((await reviews.forDay(day)).single.decision, isNull);
  });

  test(
    'El respaldo conserva las decisiones y admite formato anterior',
    () async {
      await employees.add('001', 'Ana Pérez');
      await attendance.record('001', AttendanceKind.entry);
      final eventId = (await reviews.forDay(day)).single.eventId;
      await reviews.review(
        eventId,
        ReviewDecision.rejected,
        'No hay evidencia para confirmar la identidad.',
      );
      final exported = (await backups.capture()).encode();
      final snapshot = BackupSnapshot.decode(exported);
      expect(snapshot.reviews, hasLength(1));
      await backups.restore(snapshot);
      expect(
        (await reviews.forDay(day)).single.decision,
        ReviewDecision.rejected,
      );

      final legacyData =
          jsonDecode(utf8.decode(exported)) as Map<String, dynamic>;
      legacyData['version'] = 1;
      legacyData.remove('attendanceReviews');
      final oldBackup = BackupSnapshot.decode(
        utf8.encode(jsonEncode(legacyData)),
      );
      expect(oldBackup.reviews, isEmpty);
    },
  );
}
