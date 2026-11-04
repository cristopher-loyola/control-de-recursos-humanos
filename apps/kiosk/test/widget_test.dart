import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/employees/employee_store.dart';
import 'package:kiosk/employees/employees_page.dart';

class MemoryEmployeeStore extends EmployeeStore {
  MemoryEmployeeStore() : super(authorize: () {});
  final employees = <Employee>[];

  @override
  Future<List<Employee>> list() async => List.of(employees);

  @override
  Future<String> register(String name, {int? departmentId}) async {
    final number = (employees.length + 1).toString();
    employees.add(Employee(number: number, name: name.trim()));
    return number;
  }
}

void main() {
  testWidgets(
    'El alta asigna el número consecutivo y abre el registro facial',
    (tester) async {
      final store = MemoryEmployeeStore()
        ..employees.add(const Employee(number: '1', name: 'Ana Pérez'));
      Employee? captured;
      await tester.pumpWidget(
        MaterialApp(
          home: EmployeesPage(
            store: store,
            onEnrollFace: (employee) async {
              captured = employee;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('2'),
        findsOneWidget,
        reason: 'Muestra el próximo número.',
      );
      await tester.enterText(find.byType(TextFormField), 'María López');
      final save = find.text('Guardar empleado');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(captured?.number, '2');
      expect(captured?.name, 'María López');
      expect(
        find.text('María López quedó registrado con el No. 2.'),
        findsOneWidget,
      );
      expect(find.textContaining('Rostro pendiente'), findsNWidgets(2));
    },
  );

  testWidgets('Exige un nombre válido antes de guardar', (tester) async {
    final store = MemoryEmployeeStore();
    await tester.pumpWidget(MaterialApp(home: EmployeesPage(store: store)));
    await tester.pumpAndSettle();
    final save = find.text('Guardar empleado');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Escribe el nombre.'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'Ana 123');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(store.employees, isEmpty);
  });
}
