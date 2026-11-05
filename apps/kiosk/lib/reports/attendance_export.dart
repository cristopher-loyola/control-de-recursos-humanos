import 'dart:typed_data';

import 'attendance_report.dart';
import 'report_store.dart';
import 'xlsx_writer.dart';

const _weekdays = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];

String _date(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

String _time(DateTime d) {
  final local = d.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

String _status(DayStatus status) => switch (status) {
  DayStatus.onTime => 'A tiempo',
  DayStatus.late => 'Retardo',
  DayStatus.absent => 'Falta',
  DayStatus.pending => 'Por llegar',
  DayStatus.notScheduled => 'Sin horario',
};

/// Libro de Excel con el concentrado, el detalle diario y los festivos del periodo.
Uint8List buildAttendanceWorkbook({
  required ReportData data,
  required String periodLabel,
  required String departmentLabel,
  required DateTime generatedAt,
  String? organizationName,
}) {
  final title = ['Asistencia · $periodLabel', ?organizationName].join(' · ');
  final subtitle =
      '$departmentLabel · Generado el ${_date(generatedAt)} a las ${_time(generatedAt)}';

  final summary =
      XlsxSheet(
          'Resumen',
          widths: [10, 32, 22, 12, 12, 11, 11, 14, 9, 13],
          freezeRows: 4,
        )
        ..add([title], XlsxStyle.title)
        ..add([subtitle], XlsxStyle.muted)
        ..add([])
        ..add([
          'No.',
          'Empleado',
          'Departamento',
          'Días lab.',
          'Asistencias',
          'A tiempo',
          'Retardos',
          'Min. de retraso',
          'Faltas',
          '% asistencia',
        ], XlsxStyle.header);
  for (final s in data.summaries) {
    final number = int.tryParse(s.employee.number) ?? s.employee.number;
    if (!s.hasSchedule) {
      summary.add([
        number,
        s.employee.name,
        const XlsxCell('Sin departamento', XlsxStyle.muted),
      ]);
      continue;
    }
    summary.add([
      number,
      s.employee.name,
      s.departmentName,
      s.workDays,
      s.attended,
      s.onTime,
      s.late,
      s.lateMinutes,
      s.absent,
      XlsxCell(
        s.workDays == 0 ? null : s.attended / s.workDays,
        XlsxStyle.percent,
      ),
    ]);
  }

  final detail =
      XlsxSheet(
        'Detalle',
        widths: [10, 32, 22, 12, 7, 12, 10, 14],
        freezeRows: 1,
      )..add([
        'No.',
        'Empleado',
        'Departamento',
        'Fecha',
        'Día',
        'Estado',
        'Entrada',
        'Min. de retraso',
      ], XlsxStyle.header);
  final days =
      [
        for (final s in data.summaries)
          for (final d in s.days) (s, d),
      ]..sort((a, b) {
        final byDay = a.$2.day.compareTo(b.$2.day);
        return byDay != 0
            ? byDay
            : a.$1.employee.name.toLowerCase().compareTo(
                b.$1.employee.name.toLowerCase(),
              );
      });
  for (final (s, d) in days) {
    detail.add([
      int.tryParse(s.employee.number) ?? s.employee.number,
      s.employee.name,
      s.departmentName,
      _date(d.day),
      _weekdays[d.day.weekday - 1],
      _status(d.status),
      d.entryAt == null ? null : _time(d.entryAt!),
      d.lateBy,
    ]);
  }

  final sheets = [summary, detail];
  if (data.holidays.isNotEmpty) {
    final holidays = XlsxSheet(
      'Festivos',
      widths: [12, 7, 36, 22],
      freezeRows: 1,
    )..add(['Fecha', 'Día', 'Motivo', 'Aplica a'], XlsxStyle.header);
    for (final h in data.holidays) {
      holidays.add([
        _date(h.day),
        _weekdays[h.day.weekday - 1],
        h.name,
        h.departmentId == null
            ? 'Toda la empresa'
            : data.departments
                      .where((d) => d.id == h.departmentId)
                      .map((d) => d.name)
                      .firstOrNull ??
                  'Departamento',
      ]);
    }
    sheets.add(holidays);
  }
  return buildXlsx(sheets);
}
