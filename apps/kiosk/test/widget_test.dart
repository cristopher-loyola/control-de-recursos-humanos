import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/employees/employee_store.dart';
import 'package:kiosk/main.dart';

class MemoryEmployeeStore extends EmployeeStore {
  final employees = <Employee>[];

  @override
  Future<List<Employee>> list() async => List.of(employees);

  @override
  Future<void> add(String number, String name) async {
    if (employees.any(
      (employee) => employee.number == number.trim().toUpperCase(),
    )) {
      throw DuplicateEmployee();
    }
    employees.add(
      Employee(number: number.trim().toUpperCase(), name: name.trim()),
    );
  }
}

void main() {
  testWidgets('Valida campos, muestra el empleado y rechaza duplicados', (
    tester,
  ) async {
    final store = MemoryEmployeeStore();
    await tester.pumpWidget(MyApp(store: store));
    await tester.pumpAndSettle();
    final save = find.text('Guardar empleado');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Escribe el número de empleado.'), findsOneWidget);
    expect(store.employees, isEmpty);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), '001');
    await tester.enterText(fields.at(1), 'Ana Pérez');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Ana Pérez'), findsOneWidget);
    expect(store.employees, hasLength(1));

    await tester.enterText(fields.at(0), '001');
    await tester.enterText(fields.at(1), 'Otra persona');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Ya existe un empleado con ese número.'), findsOneWidget);
    expect(store.employees, hasLength(1));
  });
}
