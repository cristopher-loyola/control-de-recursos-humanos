import 'dart:typed_data';

import '../reports/xlsx_writer.dart';
import 'payroll.dart';
import 'payroll_store.dart';

String _date(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

XlsxCell _money(int? cents) =>
    XlsxCell(cents == null ? null : cents / 100, XlsxStyle.money);

/// Libro de Excel con la pre-nómina del periodo, lista para el sistema de
/// nómina de la empresa. No incluye impuestos ni otras deducciones.
Uint8List buildPayrollWorkbook({
  required PayrollData data,
  required DateTime generatedAt,
  String? organizationName,
}) {
  final policy = data.policy;
  final title = [
    'Pre-nómina · ${_date(data.start)} al ${_date(data.lastDay)}',
    ?organizationName,
  ].join(' · ');
  final status = data.closure == null
      ? 'Periodo abierto: los montos pueden cambiar'
      : 'Cerrado el ${_date(data.closure!.closedAt.toLocal())} por ${data.closure!.actor}';
  final rules = [
    policy.kind.label,
    '${formatDays(policy.paidDays)} días pagados',
    'falta = ${formatDays(policy.absenceDays)} días de salario',
    policy.latesPerAbsence == 0
        ? 'retardos sin descuento'
        : '${policy.latesPerAbsence} retardos = 1 falta',
  ].join(' · ');
  final sheet =
      XlsxSheet(
          'Pre-nómina',
          widths: [10, 32, 22, 14, 12, 9, 10, 15, 12, 14, 14, 14],
          freezeRows: 5,
        )
        ..add([title], XlsxStyle.title)
        ..add([status], XlsxStyle.muted)
        ..add([rules], XlsxStyle.muted)
        ..add([])
        ..add([
          'No.',
          'Empleado',
          'Departamento',
          'Salario diario',
          'Días pagados',
          'Faltas',
          'Retardos',
          'Retardos a falta',
          'Incompletas',
          'Percepción',
          'Descuento',
          'Total',
        ], XlsxStyle.header);
  var gross = 0;
  var deduction = 0;
  for (final line in data.lines) {
    final number = int.tryParse(line.number) ?? line.number;
    if (!line.hasSchedule) {
      sheet.add([
        number,
        line.name,
        const XlsxCell('Sin departamento', XlsxStyle.muted),
      ]);
      continue;
    }
    gross += line.gross ?? 0;
    deduction += line.deduction ?? 0;
    sheet.add([
      number,
      line.name,
      line.departmentName,
      line.dailyWage == null
          ? const XlsxCell('Sin salario', XlsxStyle.muted)
          : _money(line.dailyWage),
      line.paidDays,
      line.absences,
      line.lates,
      line.latesAsAbsences,
      line.incomplete,
      _money(line.gross),
      _money(line.deduction),
      _money(line.total),
    ]);
  }
  sheet
    ..add([])
    ..add([
      null,
      'Total',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      _money(gross),
      _money(deduction),
      _money(gross - deduction),
    ]);
  return buildXlsx([sheet]);
}
