import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/attendance/attendance_review_store.dart';
import 'package:kiosk/attendance/attendance_store.dart';
import 'package:kiosk/backup/backup_service.dart';
import 'package:kiosk/backup/backup_snapshot.dart';
import 'package:kiosk/database/local_database.dart';
import 'package:kiosk/departments/department_store.dart';
import 'package:kiosk/employees/employee_store.dart';
import 'package:kiosk/payroll/payroll.dart';
import 'package:kiosk/payroll/payroll_export.dart';
import 'package:kiosk/payroll/payroll_store.dart';
import 'package:kiosk/reports/attendance_report.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  group('Periodos y cálculo', () {
    test('Calcula semanas, quincenas y meses', () {
      const thursday = PayrollPolicy(weekStart: DateTime.thursday);
      final week = payPeriodRange(thursday, DateTime(2026, 11, 2));
      expect(week.start, DateTime(2026, 10, 29));
      expect(week.end, DateTime(2026, 11, 5));

      const fortnight = PayrollPolicy(kind: PayPeriodKind.semimonthly);
      final second = payPeriodRange(fortnight, DateTime(2026, 11, 20));
      expect(second.start, DateTime(2026, 11, 16));
      expect(second.end, DateTime(2026, 12));
      final previous = payPeriodRange(
        fortnight,
        shiftPayPeriod(fortnight, DateTime(2026, 11, 3), -1),
      );
      expect(previous.start, DateTime(2026, 10, 16));
      expect(previous.end, DateTime(2026, 11));

      const month = PayrollPolicy(kind: PayPeriodKind.monthly);
      final december = payPeriodRange(
        month,
        shiftPayPeriod(month, DateTime(2027, 1, 10), -1),
      );
      expect(december.start, DateTime(2026, 12));
      expect(december.end, DateTime(2027));
    });

    test('Descuenta faltas y convierte retardos en faltas', () {
      final start = DateTime(2026, 10, 26);
      final end = DateTime(2026, 11, 2);
      DayResult day(int d, DayStatus status) =>
          DayResult(DateTime(2026, 10, d), status);
      final summary = EmployeeSummary(
        const ReportEmployee(number: '1', name: 'Ana', departmentId: 1),
        'Producción',
        [
          day(26, DayStatus.onTime),
          day(27, DayStatus.late),
          day(28, DayStatus.late),
          day(29, DayStatus.late),
          day(30, DayStatus.absent),
        ],
      );
      final line = payrollLine(
        summary: summary,
        employeeWage: null,
        departmentWage: 30000,
        policy: const PayrollPolicy(latesPerAbsence: 2, absenceDays: 1.5),
        start: start,
        end: end,
      );
      expect(line.gross, 7 * 30000);
      expect(line.latesAsAbsences, 1);
      // (1 falta + 1 por retardos) × 1.5 días × $300.
      expect(line.deduction, 90000);
      expect(line.total, 120000);
      expect(line.ownWage, isFalse);

      final own = payrollLine(
        summary: summary,
        employeeWage: 40000,
        departmentWage: 30000,
        policy: const PayrollPolicy(),
        start: start,
        end: end,
      );
      expect(own.dailyWage, 40000);
      expect(own.ownWage, isTrue);
      expect(own.latesAsAbsences, 0);
      expect(own.deduction, 40000);
    });

    test('Paga proporcional si el alta fue dentro del periodo', () {
      final line = payrollLine(
        summary: EmployeeSummary(
          ReportEmployee(
            number: '2',
            name: 'Luis',
            departmentId: 1,
            registeredAt: DateTime(2026, 10, 30, 9),
          ),
          'Producción',
          const [],
        ),
        employeeWage: null,
        departmentWage: 35000,
        policy: const PayrollPolicy(),
        start: DateTime(2026, 10, 26),
        end: DateTime(2026, 11, 2),
      );
      expect(line.paidDays, 3);
      expect(line.gross, 105000);
    });

    test('Sin departamento no calcula montos', () {
      final line = payrollLine(
        summary: EmployeeSummary(
          const ReportEmployee(number: '3', name: 'Eva'),
          null,
          const [],
        ),
        employeeWage: 50000,
        departmentWage: null,
        policy: const PayrollPolicy(),
        start: DateTime(2026, 10, 26),
        end: DateTime(2026, 11, 2),
      );
      expect(line.gross, isNull);
      expect(line.total, isNull);
    });

    test('Da formato a importes y los lee', () {
      expect(formatMoney(123456789), r'$1,234,567.89');
      expect(formatMoney(5), r'$0.05');
      expect(parseMoney(r'$1,234.5'), 123450);
      expect(parseMoney('350'), 35000);
      expect(parseMoney(''), isNull);
      expect(parseMoney('abc'), isNull);
      expect(formatDays(7), '7');
      expect(formatDays(1.17), '1.17');
      expect(formatDays(1.5), '1.5');
    });
  });

  group('Cierre de periodo', () {
    late Directory temp;
    late LocalDatabase database;
    late EmployeeStore employees;
    late DepartmentStore departments;
    late PayrollStore payroll;
    late AttendanceReviewStore reviews;
    late DateTime now;
    var admin = true;

    setUp(() async {
      admin = true;
      now = DateTime(2026, 11, 3, 10);
      temp = await Directory.systemTemp.createTemp('rh_payroll_');
      database = LocalDatabase(
        filePath: path.join(temp.path, 'test.db'),
        factory: databaseFactoryFfi,
      );
      employees = EmployeeStore(database: database, authorize: () {});
      departments = DepartmentStore(database, authorize: () {});
      payroll = PayrollStore(
        database,
        authorize: () {},
        authorizeReopen: () {
          if (!admin) throw StateError('Solo el administrador');
        },
        actor: () => 'responsable_rh',
        clock: () => now,
      );
      reviews = AttendanceReviewStore(
        database,
        authorize: () {},
        actor: () => 'responsable_rh',
        clock: () => now,
      );
    });

    tearDown(() async {
      await database.close();
      await temp.delete(recursive: true);
    });

    Future<int> punch(
      String number,
      String kind,
      DateTime at, {
      bool approved = true,
    }) async {
      final db = await database.open();
      final id = await db.insert('attendance_events', {
        'employee_number': number,
        'kind': kind,
        'occurred_at': at.toUtc().millisecondsSinceEpoch,
      });
      if (approved) {
        await db.insert('attendance_reviews', {
          'event_id': id,
          'decision': 'approved',
          'reviewer': 'sistema',
          'reason': 'Aprobada para la prueba.',
          'reviewed_at': at.toUtc().millisecondsSinceEpoch,
        });
      }
      return id;
    }

    Future<void> seed() async {
      await departments.save(
        name: 'Producción',
        entryMinutes: 8 * 60,
        exitMinutes: 17 * 60,
        toleranceMinutes: 10,
        dailyWageCents: 30000,
      );
      final id = (await departments.list()).single.id;
      await employees.add('001', 'Ana Pérez', departmentId: id);
      await employees.add('002', 'Luis Mora', departmentId: id);
      await employees.setDailyWage('002', 40000);
      final db = await database.open();
      await db.update('employees', {'registered_at': null});
      await payroll.savePolicy(const PayrollPolicy(latesPerAbsence: 2));
      // Ana: lunes a tiempo, martes y miércoles tarde, jueves falta,
      // viernes entra y no registra salida. Luis falta toda la semana.
      for (final (day, hour, minute) in [
        (26, 7, 55),
        (27, 8, 30),
        (28, 8, 45),
      ]) {
        await punch('001', 'entry', DateTime(2026, 10, day, hour, minute));
        await punch('001', 'exit', DateTime(2026, 10, day, 17, 5));
      }
      await punch('001', 'entry', DateTime(2026, 10, 30, 8));
    }

    test('Calcula, cierra, congela y reabre con motivo', () async {
      await seed();
      final pending = await punch(
        '002',
        'entry',
        DateTime(2026, 10, 31, 9),
        approved: false,
      );
      var data = await payroll.load(DateTime(2026, 10, 28));
      final ana = data.lines.firstWhere((l) => l.number == '001');
      expect(ana.absences, 1);
      expect(ana.lates, 2);
      expect(ana.latesAsAbsences, 1);
      expect(ana.incomplete, 1);
      expect(ana.gross, 210000);
      expect(ana.total, 150000);
      final luis = data.lines.firstWhere((l) => l.number == '002');
      expect(luis.dailyWage, 40000);
      expect(luis.absences, 5);
      // Se pagan 7 días y se descuentan las 5 faltas: quedan los 2 de descanso.
      expect(luis.total, 80000);
      expect(data.pendingReviews, 1);

      await expectLater(
        payroll.close(DateTime(2026, 10, 28)),
        throwsA(isA<PayrollRuleError>()),
      );
      await reviews.review(
        pending,
        ReviewDecision.rejected,
        'El empleado no trabajó ese sábado.',
      );
      await payroll.close(DateTime(2026, 10, 28));

      // Cambiar el salario no altera un periodo cerrado.
      final id = (await departments.list()).single.id;
      await departments.save(
        id: id,
        name: 'Producción',
        entryMinutes: 8 * 60,
        exitMinutes: 17 * 60,
        toleranceMinutes: 10,
        dailyWageCents: 50000,
      );
      data = await payroll.load(DateTime(2026, 10, 28));
      expect(data.closed, isTrue);
      expect(data.closure!.actor, 'responsable_rh');
      expect(data.lines.firstWhere((l) => l.number == '001').total, 150000);

      final late = await punch(
        '002',
        'entry',
        DateTime(2026, 10, 29, 9),
        approved: false,
      );
      await expectLater(
        reviews.review(
          late,
          ReviewDecision.approved,
          'Llegó tarde por tráfico.',
        ),
        throwsA(isA<ReviewRuleError>()),
      );

      admin = false;
      await expectLater(
        payroll.reopen(DateTime(2026, 10, 28), 'Se justificó una falta.'),
        throwsStateError,
      );
      admin = true;
      await expectLater(
        payroll.reopen(DateTime(2026, 10, 28), 'corto'),
        throwsA(isA<PayrollRuleError>()),
      );
      await payroll.reopen(
        DateTime(2026, 10, 28),
        'Se actualizó el salario de Producción.',
      );
      data = await payroll.load(DateTime(2026, 10, 28));
      expect(data.closed, isFalse);
      expect(data.lines.firstWhere((l) => l.number == '001').total, 250000);

      final db = await database.open();
      await expectLater(
        db.delete('payroll_closures'),
        throwsA(isA<DatabaseException>()),
      );
      await expectLater(
        db.update('payroll_closures', {'actor': 'otra persona'}),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('No cierra un periodo que no ha terminado', () async {
      await seed();
      now = DateTime(2026, 10, 31, 12);
      await expectLater(
        payroll.close(DateTime(2026, 10, 28)),
        throwsA(isA<PayrollRuleError>()),
      );
    });

    test('El respaldo conserva salarios, reglas y cierres', () async {
      await seed();
      await payroll.close(DateTime(2026, 10, 28));
      final snapshot = BackupSnapshot.decode(
        (await BackupService(database, authorize: () {}).capture()).encode(),
      );
      expect(snapshot.payrollPolicy.single['lates_per_absence'], 2);
      expect(snapshot.payrollClosures.single['action'], 'closed');
      expect(snapshot.departments.single['daily_wage_cents'], 30000);

      final other = LocalDatabase(
        filePath: path.join(temp.path, 'other.db'),
        factory: databaseFactoryFfi,
      );
      await BackupService(other, authorize: () {}).restore(snapshot);
      final restored = await PayrollStore(
        other,
        authorize: () {},
        authorizeReopen: () {},
        actor: () => 'responsable_rh',
        clock: () => now,
      ).load(DateTime(2026, 10, 28));
      expect(restored.closed, isTrue);
      expect(restored.policy.latesPerAbsence, 2);
      expect(
        restored.lines.firstWhere((l) => l.number == '002').dailyWage,
        40000,
      );
      // Con periodos cerrados, la tablet no acepta otra restauración.
      await expectLater(
        BackupService(other, authorize: () {}).restore(snapshot),
        throwsA(isA<InvalidBackup>()),
      );
      await other.close();
    });

    test('Genera el Excel de la pre-nómina', () async {
      await seed();
      final bytes = buildPayrollWorkbook(
        data: await payroll.load(DateTime(2026, 10, 28)),
        generatedAt: now,
        organizationName: 'Taller & Hijos',
      );
      expect(bytes.sublist(0, 2), [0x50, 0x4B]);
      final out = Platform.environment['XLSX_OUT'];
      if (out != null) File(out).writeAsBytesSync(bytes);
    });
  });

  group('Salida olvidada', () {
    late Directory temp;
    late LocalDatabase database;
    late AttendanceStore attendance;
    late DateTime now;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('rh_forgotten_exit_');
      database = LocalDatabase(
        filePath: path.join(temp.path, 'test.db'),
        factory: databaseFactoryFfi,
      );
      await EmployeeStore(
        database: database,
        authorize: () {},
      ).add('001', 'Ana Pérez');
      attendance = AttendanceStore(
        database,
        authorizeRecord: () {},
        clock: () => now,
      );
    });

    tearDown(() async {
      await database.close();
      await temp.delete(recursive: true);
    });

    test('Al día siguiente vuelve a permitir la entrada', () async {
      now = DateTime(2026, 11, 2, 8);
      await attendance.record('001', AttendanceKind.entry);
      now = DateTime(2026, 11, 2, 17);
      expect(await attendance.nextFor('001'), AttendanceKind.exit);
      now = DateTime(2026, 11, 3, 8);
      expect(await attendance.nextFor('001'), AttendanceKind.entry);
      await attendance.record('001', AttendanceKind.entry);
      expect(await attendance.nextFor('001'), AttendanceKind.exit);
    });
  });
}
