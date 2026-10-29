import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk/backup/backup_snapshot.dart';

Map<String, Object?> example() => {
  'format': 'control-recursos-humanos',
  'version': 1,
  'createdAt': '2026-10-29T00:00:00.000Z',
  'employees': [
    {'id': 1, 'number': '001', 'name': 'Ana Pérez'},
  ],
  'attendance': [
    {
      'id': 1,
      'employee_number': '001',
      'kind': 'entry',
      'occurred_at': 1793232000000,
    },
  ],
};

BackupSnapshot decode(Map<String, Object?> data) =>
    BackupSnapshot.decode(utf8.encode(jsonEncode(data)));

void main() {
  test(
    'Exporta e importa nombres, ceros iniciales y movimientos sin cambios',
    () {
      final snapshot = decode(example());
      final copy = BackupSnapshot.decode(snapshot.encode());
      expect(copy.employees, snapshot.employees);
      expect(copy.events, snapshot.events);
      expect(copy.createdAt, snapshot.createdAt);
      expect(() => copy.employees.clear(), throwsUnsupportedError);
      expect(
        () => copy.employees.first['name'] = 'Cambio',
        throwsUnsupportedError,
      );
    },
  );

  test('Rechaza archivos truncados y versiones desconocidas', () {
    expect(
      () => BackupSnapshot.decode(utf8.encode('{')),
      throwsA(isA<InvalidBackup>()),
    );
    expect(
      () => decode({...example(), 'version': 99}),
      throwsA(isA<InvalidBackup>()),
    );
    expect(
      () => decode({...example(), 'createdAt': 'sin fecha'}),
      throwsA(isA<InvalidBackup>()),
    );
  });

  test('Rechaza números de empleado duplicados', () {
    final data = example();
    data['employees'] = [
      {'id': 1, 'number': '001', 'name': 'Ana'},
      {'id': 2, 'number': '001', 'name': 'José'},
    ];
    expect(() => decode(data), throwsA(isA<InvalidBackup>()));
  });

  test('Rechaza movimientos sin empleado o con fecha inválida', () {
    for (final event in [
      {'id': 1, 'employee_number': '999', 'kind': 'entry', 'occurred_at': 1000},
      {
        'id': 1,
        'employee_number': '001',
        'kind': 'entry',
        'occurred_at': 'ayer',
      },
      {
        'id': 1,
        'employee_number': '001',
        'kind': 'desconocido',
        'occurred_at': 1000,
      },
    ]) {
      expect(
        () => decode({
          ...example(),
          'attendance': [event],
        }),
        throwsA(isA<InvalidBackup>()),
      );
    }
  });
}
