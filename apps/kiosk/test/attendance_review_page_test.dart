import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/attendance/attendance_review_page.dart';
import 'package:kiosk/attendance/attendance_review_store.dart';
import 'package:kiosk/database/local_database.dart';

class MemoryReviews extends AttendanceReviewStore {
  MemoryReviews(this.time)
    : super(LocalDatabase(), authorize: () {}, actor: () => 'responsable_rh');

  final DateTime time;
  ReviewDecision? decision;
  String? reason;

  @override
  Future<List<AttendanceReviewItem>> forDay(DateTime day) async => [
    AttendanceReviewItem(
      eventId: 1,
      employeeNumber: '001',
      employeeName: 'Ana Pérez',
      kind: 'entry',
      occurredAt: time,
      decision: decision,
      reviewer: decision == null ? null : 'responsable_rh',
      reason: reason,
      reviewedAt: decision == null ? null : time,
    ),
  ];

  @override
  Future<void> review(
    int eventId,
    ReviewDecision value,
    String motivation,
  ) async {
    decision = value;
    reason = motivation;
  }
}

void main() {
  testWidgets('RH aprueba una checada manual con motivo desde la pantalla', (
    tester,
  ) async {
    final now = DateTime.now();
    final reviews = MemoryReviews(now);

    await tester.pumpWidget(
      MaterialApp(home: AttendanceReviewPage(store: reviews)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pendiente de revisión'), findsOneWidget);

    await tester.ensureVisible(find.text('Aprobar'));
    await tester.tap(find.text('Aprobar'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField),
      'Confirmé la entrada con el supervisor.',
    );
    await tester.tap(find.text('Confirmar'));
    await tester.pumpAndSettle();

    // Ya resuelta: sale de la lista de pendientes y se consulta aparte.
    expect(
      find.text('No hay checadas por revisar en este día.'),
      findsOneWidget,
    );
    await tester.tap(find.textContaining('Ver también las ya resueltas'));
    await tester.pumpAndSettle();
    expect(find.text('Aprobada'), findsOneWidget);
    expect(find.textContaining('Revisada el'), findsOneWidget);
    expect(
      (await reviews.forDay(now)).single.decision,
      ReviewDecision.approved,
    );
  });
}
