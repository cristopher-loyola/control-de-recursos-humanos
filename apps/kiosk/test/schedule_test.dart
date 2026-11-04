import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/departments/schedule.dart';

void main() {
  const day = DepartmentSchedule(
    departmentName: 'Producción',
    entryMinutes: 8 * 60,
    exitMinutes: 17 * 60,
    toleranceMinutes: 10,
  );
  const night = DepartmentSchedule(
    departmentName: 'Vigilancia',
    entryMinutes: 22 * 60,
    exitMinutes: 6 * 60,
    toleranceMinutes: 5,
  );
  String? entry(DepartmentSchedule? s, int h, int m) => scheduleIssue(
    isEntry: true,
    localTime: DateTime(2026, 11, 3, h, m),
    schedule: s,
  );
  String? exit(DepartmentSchedule? s, int h, int m) => scheduleIssue(
    isEntry: false,
    localTime: DateTime(2026, 11, 3, h, m),
    schedule: s,
  );

  test('Entrada: temprano o dentro de la tolerancia es a tiempo', () {
    expect(entry(day, 7, 40), isNull);
    expect(entry(day, 8, 0), isNull);
    expect(entry(day, 8, 10), isNull);
    expect(entry(day, 8, 11), contains('Retardo de 11 min'));
    expect(entry(day, 9, 30), contains('Retardo de 1 h 30 min'));
  });

  test('Salida: antes de la hora va a revisión, a la hora o después no', () {
    expect(exit(day, 16, 59), contains('Salida anticipada por 1 min'));
    expect(exit(day, 12, 0), contains('5 h'));
    expect(exit(day, 17, 0), isNull);
    expect(exit(day, 19, 45), isNull);
  });

  test('Turno nocturno que cruza la medianoche', () {
    expect(entry(night, 21, 50), isNull);
    expect(entry(night, 22, 5), isNull);
    expect(entry(night, 22, 20), contains('Retardo de 20 min'));
    expect(entry(night, 0, 30), contains('Retardo de 2 h 30 min'));
    expect(exit(night, 5, 0), contains('Salida anticipada por 1 h'));
    expect(exit(night, 6, 10), isNull);
  });

  test('Sin departamento siempre va a revisión', () {
    expect(entry(null, 8, 0), contains('Sin departamento'));
    expect(exit(null, 17, 0), contains('Sin departamento'));
  });
}
