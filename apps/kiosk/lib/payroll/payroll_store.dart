import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../attendance/attendance_store.dart' show openEntryLimit;
import '../audit/audit_store.dart';
import '../database/local_database.dart';
import '../holidays/holiday_store.dart' show formatDay;
import '../reports/report_store.dart';
import 'payroll.dart';

class PayrollRuleError implements Exception {
  const PayrollRuleError(this.message);
  final String message;
}

class PayrollClosure {
  const PayrollClosure({required this.closedAt, required this.actor});
  final DateTime closedAt;
  final String actor;
}

class PayrollData {
  const PayrollData({
    required this.start,
    required this.end,
    required this.policy,
    required this.lines,
    required this.pendingReviews,
    required this.ended,
    this.closure,
  });

  /// Rango [start, end) del periodo.
  final DateTime start;
  final DateTime end;

  /// Reglas con que se calculó; si está cerrado, las de ese momento.
  final PayrollPolicy policy;
  final List<PayrollLine> lines;
  final int pendingReviews;

  /// true si el periodo ya terminó y se puede cerrar.
  final bool ended;
  final PayrollClosure? closure;

  bool get closed => closure != null;
  DateTime get lastDay => DateTime(end.year, end.month, end.day - 1);
  int get incomplete => lines.fold(0, (total, l) => total + l.incomplete);
  int get withoutWage =>
      lines.where((l) => l.hasSchedule && l.dailyWage == null).length;
}

/// Indica si [day] cae en un periodo de pre-nómina cerrado.
Future<bool> isPayrollClosed(DatabaseExecutor db, DateTime day) async {
  final value = formatDay(day.toLocal());
  final rows = await db.rawQuery(
    '''
    SELECT 1 FROM payroll_closures c
    WHERE c.period_start <= ? AND c.period_end >= ? AND c.action = 'closed'
      AND c.id = (SELECT max(id) FROM payroll_closures x
                  WHERE x.period_start = c.period_start AND x.period_end = c.period_end)
    LIMIT 1
    ''',
    [value, value],
  );
  return rows.isNotEmpty;
}

class PayrollStore {
  PayrollStore(
    this.database, {
    required this.authorize,
    required this.authorizeReopen,
    required this.actor,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final LocalDatabase database;
  final void Function() authorize;

  /// Reabrir un periodo cerrado lo autoriza solo el administrador.
  final void Function() authorizeReopen;
  final String Function() actor;
  final DateTime Function() _clock;

  Future<PayrollPolicy> policy() async {
    authorize();
    final rows = await (await database.open()).query('payroll_policy');
    return rows.isEmpty
        ? const PayrollPolicy()
        : PayrollPolicy.fromRow(rows.single);
  }

  Future<void> savePolicy(PayrollPolicy policy) async {
    authorize();
    if (policy.paidDays <= 0 || policy.paidDays > 31) {
      throw const PayrollRuleError('Los días pagados van de 0.01 a 31.');
    }
    if (policy.absenceDays < 0 || policy.absenceDays > 7) {
      throw const PayrollRuleError(
        'El descuento por falta va de 0 a 7 días de salario.',
      );
    }
    if (policy.latesPerAbsence < 0 || policy.latesPerAbsence > 31) {
      throw const PayrollRuleError('Los retardos por falta van de 0 a 31.');
    }
    final db = await database.open();
    await db.transaction((txn) async {
      authorize();
      await txn.insert(
        'payroll_policy',
        policy.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await writeAudit(
        txn,
        action: AuditAction.payrollPolicyChanged,
        actor: actor(),
        details: {
          'period': policy.kind.label,
          'paidDays': policy.paidDays,
          'absenceDays': policy.absenceDays,
          'latesPerAbsence': policy.latesPerAbsence,
        },
      );
    });
  }

  Future<PayrollData> load(DateTime anchor) async {
    final current = await policy();
    final range = payPeriodRange(current, anchor);
    final now = _clock();
    final ended = !range.end.isAfter(now);
    final db = await database.open();
    final closure = await _latestClosure(db, range.start, range.end);
    if (closure != null && closure['action'] == 'closed') {
      final summary =
          jsonDecode(closure['summary'] as String) as Map<String, dynamic>;
      return PayrollData(
        start: range.start,
        end: range.end,
        policy: PayrollPolicy.fromRow(
          (summary['policy'] as Map).cast<String, Object?>(),
        ),
        lines: [
          for (final line in summary['lines'] as List)
            PayrollLine.fromJson(line as Map<String, dynamic>),
        ],
        pendingReviews: 0,
        ended: ended,
        closure: PayrollClosure(
          closedAt: DateTime.fromMillisecondsSinceEpoch(
            closure['occurred_at'] as int,
            isUtc: true,
          ),
          actor: closure['actor'] as String,
        ),
      );
    }
    final report = await ReportStore(
      database,
      authorize: authorize,
      clock: _clock,
    ).load(start: range.start, end: range.end);
    final employeeWages = {
      for (final row in await db.query(
        'employees',
        columns: ['number', 'daily_wage_cents'],
      ))
        row['number'] as String: row['daily_wage_cents'] as int?,
    };
    final departmentWages = {
      for (final row in await db.query(
        'departments',
        columns: ['id', 'daily_wage_cents'],
      ))
        row['id'] as int: row['daily_wage_cents'] as int?,
    };
    final incomplete = await _incompleteEntries(db, range.start, range.end);
    return PayrollData(
      start: range.start,
      end: range.end,
      policy: current,
      lines: [
        for (final summary in report.summaries)
          payrollLine(
            summary: summary,
            employeeWage: employeeWages[summary.employee.number],
            departmentWage: departmentWages[summary.employee.departmentId],
            policy: current,
            start: range.start,
            end: range.end,
            incomplete: incomplete[summary.employee.number] ?? 0,
          ),
      ],
      pendingReviews: report.pendingReviews,
      ended: ended,
    );
  }

  /// Congela los montos del periodo. Exige que haya terminado y que no queden
  /// checadas por revisar.
  Future<void> close(DateTime anchor) async {
    authorize();
    final data = await load(anchor);
    if (data.closed) {
      throw const PayrollRuleError('El periodo ya está cerrado.');
    }
    if (!data.ended) {
      throw const PayrollRuleError(
        'El periodo todavía no termina. Ciérralo después del último día.',
      );
    }
    final db = await database.open();
    await db.transaction((txn) async {
      authorize();
      final pending = await txn.rawQuery(
        '''
        SELECT count(*) AS n FROM attendance_events a
        WHERE a.occurred_at >= ? AND a.occurred_at < ?
          AND NOT EXISTS (SELECT 1 FROM attendance_reviews r WHERE r.event_id = a.id)
        ''',
        [
          data.start.toUtc().millisecondsSinceEpoch,
          data.end.toUtc().millisecondsSinceEpoch,
        ],
      );
      final count = pending.single['n'] as int;
      if (count > 0) {
        throw PayrollRuleError(
          count == 1
              ? 'Queda 1 checada por revisar en el periodo.'
              : 'Quedan $count checadas por revisar en el periodo.',
        );
      }
      final latest = await _latestClosure(txn, data.start, data.end);
      if (latest != null && latest['action'] == 'closed') {
        throw const PayrollRuleError('El periodo ya está cerrado.');
      }
      final now = _clock().toUtc();
      final name = actor();
      await txn.insert('payroll_closures', {
        'period_start': formatDay(data.start),
        'period_end': formatDay(data.lastDay),
        'action': 'closed',
        'actor': name,
        'occurred_at': now.millisecondsSinceEpoch,
        'summary': jsonEncode({
          'policy': data.policy.toRow(),
          'lines': [for (final line in data.lines) line.toJson()],
        }),
      });
      await writeAudit(
        txn,
        action: AuditAction.payrollClosed,
        actor: name,
        time: now,
        details: {
          'start': formatDay(data.start),
          'end': formatDay(data.lastDay),
          'employees': data.lines.length,
          'total': data.lines.fold<int>(0, (t, l) => t + (l.total ?? 0)),
        },
      );
    });
  }

  Future<void> reopen(DateTime anchor, String reason) async {
    authorizeReopen();
    final trimmed = reason.trim();
    if (trimmed.length < 10 || trimmed.length > 500) {
      throw const PayrollRuleError('Escribe un motivo de 10 a 500 caracteres.');
    }
    final range = payPeriodRange(await policy(), anchor);
    final lastDay = DateTime(
      range.end.year,
      range.end.month,
      range.end.day - 1,
    );
    final db = await database.open();
    await db.transaction((txn) async {
      authorizeReopen();
      final latest = await _latestClosure(txn, range.start, range.end);
      if (latest == null || latest['action'] != 'closed') {
        throw const PayrollRuleError('El periodo no está cerrado.');
      }
      final now = _clock().toUtc();
      final name = actor();
      await txn.insert('payroll_closures', {
        'period_start': formatDay(range.start),
        'period_end': formatDay(lastDay),
        'action': 'reopened',
        'actor': name,
        'reason': trimmed,
        'occurred_at': now.millisecondsSinceEpoch,
      });
      await writeAudit(
        txn,
        action: AuditAction.payrollReopened,
        actor: name,
        time: now,
        details: {
          'start': formatDay(range.start),
          'end': formatDay(lastDay),
          'reason': trimmed,
        },
      );
    });
  }

  Future<Map<String, Object?>?> _latestClosure(
    DatabaseExecutor db,
    DateTime start,
    DateTime end,
  ) async {
    final rows = await db.query(
      'payroll_closures',
      where: 'period_start = ? AND period_end = ?',
      whereArgs: [
        formatDay(start),
        formatDay(DateTime(end.year, end.month, end.day - 1)),
      ],
      orderBy: 'id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single;
  }

  /// Entradas del periodo que nunca tuvieron salida: la siguiente checada del
  /// empleado fue otra entrada, o ya pasó el tiempo máximo de una jornada.
  Future<Map<String, int>> _incompleteEntries(
    DatabaseExecutor db,
    DateTime start,
    DateTime end,
  ) async {
    final from = start.toUtc().millisecondsSinceEpoch;
    final to = end.toUtc().millisecondsSinceEpoch;
    final rows = await db.rawQuery(
      '''
      SELECT employee_number, kind, occurred_at FROM attendance_events
      WHERE occurred_at >= ? AND occurred_at < ?
      ORDER BY employee_number, id
      ''',
      [from, to + openEntryLimit.inMilliseconds],
    );
    final now = _clock().toUtc().millisecondsSinceEpoch;
    final counts = <String, int>{};
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final at = row['occurred_at'] as int;
      if (row['kind'] != 'entry' || at >= to) continue;
      final number = row['employee_number'] as String;
      final next =
          i + 1 < rows.length && rows[i + 1]['employee_number'] == number
          ? rows[i + 1]
          : null;
      final open = next == null
          ? now - at >= openEntryLimit.inMilliseconds
          : next['kind'] == 'entry';
      if (open) counts[number] = (counts[number] ?? 0) + 1;
    }
    return counts;
  }
}
