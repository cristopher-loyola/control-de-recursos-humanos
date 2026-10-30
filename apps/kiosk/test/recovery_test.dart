import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:kiosk/auth/admin_auth.dart';
import 'package:kiosk/database/local_database.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('El código recupera el acceso una vez y se reemplaza', () async {
    final database = LocalDatabase(
      filePath: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    final auth = AdminAuth(database);
    addTearDown(() async {
      auth.dispose();
      await database.close();
    });

    await auth.initialize();
    await auth.create('admin', 'contraseña inicial segura');
    final originalCode = auth.pendingRecoveryCode;
    expect(originalCode, isNotNull);
    expect(originalCode!.replaceAll('-', ''), hasLength(32));

    final row = (await (await database.open()).query('administrator')).single;
    expect(row['recovery_salt'], isNotNull);
    expect(row['recovery_hash'], isNotNull);
    expect(row.values.join(), isNot(contains(originalCode)));

    auth.acknowledgeRecoveryCode();
    auth.logout();
    await auth.recover(originalCode, 'contraseña nueva segura');
    final nextCode = auth.pendingRecoveryCode;
    expect(nextCode, isNotNull);
    expect(nextCode, isNot(originalCode));
    auth.logout();

    await expectLater(
      auth.recover(originalCode, 'otra contraseña segura'),
      throwsA(isA<AuthenticationError>()),
    );
    await auth.login('admin', 'contraseña nueva segura');
    expect(auth.isAuthenticated, isTrue);
  });
}
