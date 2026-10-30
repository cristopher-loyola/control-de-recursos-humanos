import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/employees/employee_store.dart';
import 'package:kiosk/employees/employee_validation.dart';

void main() {
  test('El número solo admite dígitos y conserva ceros iniciales', () {
    expect(validateEmployeeNumber('001'), isNull);
    for (final value in ['', 'TADEO', 'EMP-001', '1.5', '-1', '1 2']) {
      expect(validateEmployeeNumber(value), isNotNull, reason: value);
    }
  });

  test('El nombre admite acentos y separadores pero no números', () {
    for (final value in ['José Muñoz', 'María-José', "Ana D'Ávila", '李明']) {
      expect(validateEmployeeName(value), isNull, reason: value);
    }
    for (final value in ['', '1', 'Ana123', '---', 'Ana@']) {
      expect(validateEmployeeName(value), isNotNull, reason: value);
    }
  });

  test(
    'El almacenamiento rechaza datos inválidos antes de abrir SQLite',
    () async {
      final store = EmployeeStore(authorize: () {});
      await expectLater(store.add('TADEO', 'Ana'), throwsArgumentError);
      await expectLater(store.add('1', '123'), throwsArgumentError);
    },
  );
}
