import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/attendance/attendance_store.dart';
import 'package:kiosk/auth/access_gate.dart';
import 'package:kiosk/auth/admin_auth.dart';
import 'package:kiosk/backup/backup_service.dart';
import 'package:kiosk/database/local_database.dart';
import 'package:kiosk/employees/employee_store.dart';

class MemoryAuth extends AdminAuth {
  MemoryAuth({bool configured = true})
    : _hasAccount = configured,
      _hasOrganization = configured,
      super(LocalDatabase());
  bool _hasAccount;
  bool _hasOrganization;
  bool _active = false;
  @override
  bool get configured => _hasAccount;
  @override
  bool get isAuthenticated => _active;
  @override
  bool get isAdministrator => _active;
  @override
  bool get organizationConfigured => _hasOrganization;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> create(String username, String password) async {
    _hasAccount = true;
    _active = true;
    notifyListeners();
  }

  @override
  Future<void> login(String username, String password) async {
    if (password != 'Una frase segura') {
      throw const AuthenticationError('Usuario o contraseña incorrectos.');
    }
    _active = true;
    notifyListeners();
  }

  @override
  Future<void> saveOrganization(String name) async {
    _hasOrganization = true;
    notifyListeners();
  }

  @override
  void logout() {
    _active = false;
    notifyListeners();
  }

  @override
  void touch() {}
  @override
  void requireAdmin() {
    if (!_active) {
      throw AdminAccessRequired();
    }
  }
}

class MemoryEmployees extends EmployeeStore {
  MemoryEmployees() : super(authorize: () {});
  @override
  Future<List<Employee>> list() async => [];
}

class MemoryAttendance extends AttendanceStore {
  MemoryAttendance() : super(LocalDatabase());
  @override
  Future<List<AttendanceEvent>> forDay(DateTime day) async => [];
}

Widget app(MemoryAuth auth) => MaterialApp(
  home: AccessGate(
    auth: auth,
    employees: MemoryEmployees(),
    attendance: MemoryAttendance(),
    backups: BackupService(LocalDatabase(), authorize: auth.requireAdmin),
  ),
);

Future<void> tapFormButton(WidgetTester tester, String label) async {
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
  final button = find.widgetWithText(FilledButton, label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  expect(
    button.hitTestable(),
    findsOneWidget,
    reason: 'El botón debe estar visible y recibir el toque.',
  );
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Al iniciar muestra el checador y exige contraseña para administrar',
    (tester) async {
      final auth = MemoryAuth();
      await tester.pumpWidget(app(auth));
      await tester.pumpAndSettle();
      expect(find.text('Guardar empleado'), findsNothing);
      await tester.tap(find.text('Administrar'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'admin');
      await tester.enterText(find.byType(TextFormField).at(1), 'incorrecta');
      await tapFormButton(tester, 'Entrar');
      expect(find.text('Usuario o contraseña incorrectos.'), findsOneWidget);
      expect(find.text('Guardar empleado'), findsNothing);

      await tester.enterText(
        find.byType(TextFormField).at(1),
        'Una frase segura',
      );
      await tapFormButton(tester, 'Entrar');
      expect(find.text('Guardar empleado'), findsOneWidget);
      await tester.tap(find.byTooltip('Cerrar sesión y abrir checador'));
      await tester.pumpAndSettle();
      expect(find.text('Guardar empleado'), findsNothing);
      expect(find.text('Administrar'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      auth.dispose();
    },
  );

  testWidgets('La configuración inicial exige repetir la contraseña', (
    tester,
  ) async {
    final auth = MemoryAuth(configured: false);
    await tester.pumpWidget(app(auth));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'admin');
    await tester.enterText(fields.at(1), 'Una frase segura');
    await tester.enterText(fields.at(2), 'No coincide');
    await tapFormButton(tester, 'Crear administrador');
    expect(find.text('Las contraseñas no coinciden.'), findsOneWidget);
    expect(auth.configured, isFalse);
    await tester.enterText(fields.at(2), 'Una frase segura');
    await tapFormButton(tester, 'Crear administrador');
    expect(auth.configured, isTrue);
    expect(find.text('Configurar organización'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'Organización piloto');
    await tapFormButton(tester, 'Guardar organización');
    expect(auth.organizationConfigured, isTrue);
    expect(find.text('Guardar empleado'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    auth.dispose();
  });
}
