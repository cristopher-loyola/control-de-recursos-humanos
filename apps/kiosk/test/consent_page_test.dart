import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/database/local_database.dart';
import 'package:kiosk/vision/consent_page.dart';
import 'package:kiosk/vision/consent_store.dart';

class MemoryConsentStore extends ConsentStore {
  MemoryConsentStore(this.time)
    : super(LocalDatabase(), authorize: () {}, actor: () => 'administrador');

  final DateTime time;
  ConsentKind? current;
  String? reference;

  @override
  Future<List<ConsentItem>> list() async => [
    ConsentItem(
      employeeNumber: '001',
      employeeName: 'Ana Pérez',
      kind: current,
      documentReference: reference,
      actor: current == null ? null : 'administrador',
      occurredAt: current == null ? null : time,
    ),
  ];

  @override
  Future<void> record(
    String employeeNumber,
    ConsentKind kind,
    String folio,
  ) async {
    current = kind;
    reference = folio;
  }
}

void main() {
  testWidgets('Registra un folio y permite documentar la revocación', (
    tester,
  ) async {
    final store = MemoryConsentStore(DateTime(2026, 10, 30));
    String? checkedEmployee;
    await tester.pumpWidget(
      MaterialApp(
        home: ConsentPage(
          store: store,
          onOpenFaceCheck: (number) => checkedEmployee = number,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Comprobar encuadre facial'), findsNothing);

    await tester.tap(find.text('Registrar folio firmado'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '123');
    await tester.tap(find.text('Guardar folio'));
    await tester.pumpAndSettle();
    expect(
      find.text('Escribe un folio de al menos 5 caracteres.'),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextFormField), 'CONS-2026-001');
    await tester.tap(find.text('Guardar folio'));
    await tester.pumpAndSettle();
    expect(store.current, ConsentKind.recorded);
    expect(find.text('Documento de consentimiento registrado'), findsOneWidget);
    await tester.tap(find.text('Comprobar encuadre facial'));
    expect(checkedEmployee, '001');

    await tester.tap(find.text('Registrar revocación'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'REV-2026-001');
    await tester.tap(find.text('Guardar folio'));
    await tester.pumpAndSettle();
    expect(store.current, ConsentKind.revoked);
    expect(find.text('Consentimiento revocado'), findsOneWidget);
    expect(find.text('Comprobar encuadre facial'), findsNothing);
  });
}
