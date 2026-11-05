import 'dart:math';

import '../reports/attendance_report.dart';

enum PayPeriodKind {
  weekly('weekly', 'Semanal', 7),
  semimonthly('semimonthly', 'Quincenal', 15),
  monthly('monthly', 'Mensual', 30);

  const PayPeriodKind(this.value, this.label, this.defaultPaidDays);
  final String value;
  final String label;
  final double defaultPaidDays;
}

/// Reglas que define RH para su empresa.
class PayrollPolicy {
  const PayrollPolicy({
    this.kind = PayPeriodKind.weekly,
    this.weekStart = DateTime.monday,
    this.paidDays = 7,
    this.absenceDays = 1,
    this.latesPerAbsence = 0,
  });
  final PayPeriodKind kind;

  /// Día en que empieza la semana de pago (lunes = 1 … domingo = 7).
  final int weekStart;

  /// Días de salario que se pagan por periodo completo.
  final double paidDays;

  /// Días de salario que descuenta cada falta.
  final double absenceDays;

  /// Cuántos retardos equivalen a una falta; 0 = los retardos no descuentan.
  final int latesPerAbsence;

  factory PayrollPolicy.fromRow(Map<String, Object?> row) => PayrollPolicy(
    kind: PayPeriodKind.values.firstWhere(
      (kind) => kind.value == row['period_kind'],
    ),
    weekStart: row['week_start'] as int,
    paidDays: (row['paid_days'] as num).toDouble(),
    absenceDays: (row['absence_days'] as num).toDouble(),
    latesPerAbsence: row['lates_per_absence'] as int,
  );

  Map<String, Object?> toRow() => {
    'id': 1,
    'period_kind': kind.value,
    'week_start': weekStart,
    'paid_days': paidDays,
    'absence_days': absenceDays,
    'lates_per_absence': latesPerAbsence,
  };
}

/// Rango [start, end) del periodo de pago que contiene [anchor].
({DateTime start, DateTime end}) payPeriodRange(
  PayrollPolicy policy,
  DateTime anchor,
) {
  final day = DateTime(anchor.year, anchor.month, anchor.day);
  switch (policy.kind) {
    case PayPeriodKind.weekly:
      final back = (day.weekday - policy.weekStart) % 7;
      final start = DateTime(day.year, day.month, day.day - back);
      return (
        start: start,
        end: DateTime(start.year, start.month, start.day + 7),
      );
    case PayPeriodKind.semimonthly:
      return day.day <= 15
          ? (
              start: DateTime(day.year, day.month),
              end: DateTime(day.year, day.month, 16),
            )
          : (
              start: DateTime(day.year, day.month, 16),
              end: DateTime(day.year, day.month + 1),
            );
    case PayPeriodKind.monthly:
      return (
        start: DateTime(day.year, day.month),
        end: DateTime(day.year, day.month + 1),
      );
  }
}

/// Fecha dentro del periodo anterior (-1) o siguiente (+1).
DateTime shiftPayPeriod(PayrollPolicy policy, DateTime anchor, int step) {
  final range = payPeriodRange(policy, anchor);
  return step < 0
      ? DateTime(range.start.year, range.start.month, range.start.day - 1)
      : range.end;
}

/// Renglón de la pre-nómina de un empleado. Los montos van en centavos.
class PayrollLine {
  const PayrollLine({
    required this.number,
    required this.name,
    this.departmentName,
    this.dailyWage,
    this.ownWage = false,
    this.paidDays = 0,
    this.absences = 0,
    this.lates = 0,
    this.latesAsAbsences = 0,
    this.incomplete = 0,
    this.gross,
    this.deduction,
  });
  final String number;
  final String name;
  final String? departmentName;

  /// Salario diario aplicado; null si no hay salario capturado.
  final int? dailyWage;

  /// true si el salario es del empleado y no el de su departamento.
  final bool ownWage;
  final double paidDays;
  final int absences;
  final int lates;
  final int latesAsAbsences;

  /// Entradas sin salida en el periodo: se marcan, no se descuentan.
  final int incomplete;
  final int? gross;
  final int? deduction;

  int? get total => gross == null ? null : gross! - deduction!;
  bool get hasSchedule => departmentName != null;

  Map<String, Object?> toJson() => {
    'number': number,
    'name': name,
    'department': departmentName,
    'dailyWage': dailyWage,
    'ownWage': ownWage,
    'paidDays': paidDays,
    'absences': absences,
    'lates': lates,
    'latesAsAbsences': latesAsAbsences,
    'incomplete': incomplete,
    'gross': gross,
    'deduction': deduction,
  };

  factory PayrollLine.fromJson(Map<String, dynamic> json) => PayrollLine(
    number: json['number'] as String,
    name: json['name'] as String,
    departmentName: json['department'] as String?,
    dailyWage: json['dailyWage'] as int?,
    ownWage: json['ownWage'] as bool? ?? false,
    paidDays: (json['paidDays'] as num).toDouble(),
    absences: json['absences'] as int,
    lates: json['lates'] as int,
    latesAsAbsences: json['latesAsAbsences'] as int,
    incomplete: json['incomplete'] as int? ?? 0,
    gross: json['gross'] as int?,
    deduction: json['deduction'] as int?,
  );
}

/// Calcula lo que corresponde a cada empleado en el periodo, antes de
/// impuestos y otras deducciones.
///
/// - Base: salario diario × días pagados. Si el alta fue dentro del periodo,
///   se paga la parte proporcional de los días que estuvo dado de alta.
/// - Descuento: (faltas + retardos ÷ N, sin decimales) × días por falta ×
///   salario diario. Nunca supera la base.
/// - Sin departamento no hay horario contra qué medir: no se calcula monto.
PayrollLine payrollLine({
  required EmployeeSummary summary,
  required int? employeeWage,
  required int? departmentWage,
  required PayrollPolicy policy,
  required DateTime start,
  required DateTime end,
  int incomplete = 0,
}) {
  final wage = employeeWage ?? departmentWage;
  final latesAsAbsences = policy.latesPerAbsence == 0
      ? 0
      : summary.late ~/ policy.latesPerAbsence;
  final periodDays = calendarDays(start, end);
  final registered = summary.employee.registeredAt?.toLocal();
  final from = registered == null
      ? start
      : DateTime(registered.year, registered.month, registered.day);
  final employedDays = from.isAfter(start)
      ? calendarDays(from, end).clamp(0, periodDays)
      : periodDays;
  final paidDays = policy.paidDays * employedDays / periodDays;
  int? gross;
  int? deduction;
  if (wage != null && summary.hasSchedule) {
    gross = (wage * paidDays).round();
    deduction = min(
      gross,
      (wage * (summary.absent + latesAsAbsences) * policy.absenceDays).round(),
    );
  }
  return PayrollLine(
    number: summary.employee.number,
    name: summary.employee.name,
    departmentName: summary.departmentName,
    dailyWage: wage,
    ownWage: employeeWage != null,
    paidDays: double.parse(paidDays.toStringAsFixed(2)),
    absences: summary.absent,
    lates: summary.late,
    latesAsAbsences: latesAsAbsences,
    incomplete: incomplete,
    gross: gross,
    deduction: deduction,
  );
}

/// Días naturales entre dos fechas locales, sin depender del horario de verano.
int calendarDays(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

String formatMoney(int cents) {
  final negative = cents < 0;
  final value = cents.abs();
  final whole = (value ~/ 100).toString();
  final grouped = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) grouped.write(',');
    grouped.write(whole[i]);
  }
  return '${negative ? '-' : ''}\$$grouped.${(value % 100).toString().padLeft(2, '0')}';
}

/// Convierte "1,234.5" o "$350" a centavos; null si está vacío o no es válido.
int? parseMoney(String text) {
  final clean = text.replaceAll(RegExp(r'[\s$,]'), '');
  if (clean.isEmpty || !RegExp(r'^\d{1,7}(\.\d{0,2})?$').hasMatch(clean)) {
    return null;
  }
  return (double.parse(clean) * 100).round();
}

/// Número de días con hasta dos decimales, sin ceros sobrantes: 7, 1.5, 1.17.
String formatDays(double days) {
  final text = days.toStringAsFixed(2);
  return text.replaceFirst(RegExp(r'\.?0+$'), '');
}
