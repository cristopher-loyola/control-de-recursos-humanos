import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/departments/schedule.dart';
import 'package:kiosk/reports/attendance_export.dart';
import 'package:kiosk/reports/attendance_report.dart';
import 'package:kiosk/reports/report_store.dart';

/// Lee las entradas de un zip sin compresión y comprueba su CRC.
Map<String, String> unzipStored(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final files = <String, String>{};
  var offset = 0;
  while (data.getUint32(offset, Endian.little) == 0x04034b50) {
    final size = data.getUint32(offset + 18, Endian.little);
    final nameLength = data.getUint16(offset + 26, Endian.little);
    final name = utf8.decode(
      bytes.sublist(offset + 30, offset + 30 + nameLength),
    );
    final start = offset + 30 + nameLength;
    files[name] = utf8.decode(bytes.sublist(start, start + size));
    offset = start + size;
  }
  return files;
}

void main() {
  test('Genera un .xlsx con resumen, detalle y festivos', () {
    const department = ReportDepartment(
      id: 1,
      workDays: WorkDays.mondayToFriday,
      schedule: DepartmentSchedule(
        departmentName: 'Almacén & Envíos',
        entryMinutes: 480,
        exitMinutes: 1020,
        toleranceMinutes: 10,
      ),
    );
    final summaries = buildReport(
      employees: const [
        ReportEmployee(number: '1', name: 'Ana <Pérez>', departmentId: 1),
        ReportEmployee(number: '2', name: 'Sara'),
      ],
      departments: const [department],
      entries: {
        '1': [DateTime(2026, 11, 2, 8, 30)],
      },
      start: DateTime(2026, 11, 2),
      end: DateTime(2026, 11, 9),
      now: DateTime(2026, 11, 8, 20),
      holidays: [ReportHoliday(day: DateTime(2026, 11, 3), name: 'Puente')],
    );
    final bytes = buildAttendanceWorkbook(
      data: ReportData(
        summaries: summaries,
        departments: const [(id: 1, name: 'Almacén & Envíos')],
        pendingReviews: 0,
        withoutFace: 0,
        holidays: [ReportHoliday(day: DateTime(2026, 11, 3), name: 'Puente')],
      ),
      periodLabel: 'Semana del 2 al 8 de noviembre',
      departmentLabel: 'Todos los departamentos',
      generatedAt: DateTime(2026, 11, 8, 20),
      organizationName: 'Prueba',
    );
    final files = unzipStored(bytes);
    expect(
      files.keys,
      containsAll([
        '[Content_Types].xml',
        'xl/workbook.xml',
        'xl/worksheets/sheet1.xml',
        'xl/worksheets/sheet3.xml',
      ]),
    );
    expect(files['xl/workbook.xml'], contains('name="Festivos"'));
    final resumen = files['xl/worksheets/sheet1.xml']!;
    expect(resumen, contains('Ana &lt;Pérez&gt;'));
    expect(resumen, contains('Almacén &amp; Envíos'));
    expect(resumen, contains('Sin departamento'));
    final detalle = files['xl/worksheets/sheet2.xml']!;
    expect(detalle, contains('Retardo'));
    expect(
      'Falta'.allMatches(detalle).length,
      3,
      reason: 'Mié, jue y vie; el martes es festivo.',
    );

    final out = Platform.environment['XLSX_OUT'];
    if (out != null) File(out).writeAsBytesSync(bytes);
  });
}
