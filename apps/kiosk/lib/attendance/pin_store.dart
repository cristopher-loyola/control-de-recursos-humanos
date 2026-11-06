import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../audit/audit_store.dart';
import '../auth/password_hasher.dart';
import '../database/local_database.dart';

class PinRuleError implements Exception {
  const PinRuleError(this.message);
  final String message;
}

/// Empleado que acaba de comprobar su PIN. Vale unos segundos para elegir
/// entrada o salida, igual que una identificación facial.
class PinCheck {
  PinCheck._(this.employeeNumber, this.employeeName, this._verifiedAt);
  static const validity = Duration(seconds: 20);
  final String employeeNumber;
  final String employeeName;
  final DateTime _verifiedAt;
  bool _used = false;

  /// Marca el PIN como usado; falla si ya se usó o caducó.
  void claim(DateTime now) {
    if (_used || now.difference(_verifiedAt) > validity) {
      throw const PinRuleError('El PIN caducó. Vuelve a escribirlo.');
    }
    _used = true;
  }
}

/// PIN de respaldo para checar cuando el rostro no se reconoce. Solo se guarda
/// el hash; tras 5 intentos fallidos el PIN se bloquea 15 minutos.
class PinStore {
  PinStore(
    this.database, {
    required this.authorizeAssign,
    this.actor,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final LocalDatabase database;

  /// Asignar o quitar PIN lo hace RH o el administrador.
  final void Function() authorizeAssign;
  final String Function()? actor;
  final DateTime Function() _clock;

  // El PIN tiene pocas combinaciones: lo que lo protege es el bloqueo por
  // intentos, así que basta un costo bajo para que el checador responda rápido.
  static const iterations = 20000;
  static const maxAttempts = 5;
  static const lockDuration = Duration(minutes: 15);
  static const _random = Random.secure;

  static Future<List<int>> _derive(String pin, List<int> salt, int rounds) =>
      Isolate.run(() async {
        final key = await Pbkdf2.hmacSha256(
          iterations: rounds,
          bits: 256,
        ).deriveKeyFromPassword(password: pin, nonce: salt);
        return key.extractBytes();
      });

  /// Mensaje de error si el PIN no sirve, o null si es válido.
  static String? validate(String pin) {
    if (!RegExp(r'^\d{4,6}$').hasMatch(pin)) {
      return 'El PIN debe tener de 4 a 6 números.';
    }
    final digits = pin.codeUnits;
    final same = digits.every((d) => d == digits.first);
    var up = true;
    var down = true;
    for (var i = 1; i < digits.length; i++) {
      up &= digits[i] == digits[i - 1] + 1;
      down &= digits[i] == digits[i - 1] - 1;
    }
    if (same || up || down) {
      return 'Elige un PIN menos obvio (no 1111 ni 1234).';
    }
    return null;
  }

  /// PIN aleatorio de 4 números que pasa [validate].
  static String generate() {
    final random = _random();
    while (true) {
      final pin = List.generate(4, (_) => random.nextInt(10)).join();
      if (validate(pin) == null) return pin;
    }
  }

  Future<Set<String>> withPin() async {
    final rows = await (await database.open()).query(
      'employee_pins',
      columns: ['employee_number'],
    );
    return {for (final row in rows) row['employee_number'] as String};
  }

  /// Asigna o cambia el PIN; [pin] null lo quita.
  Future<void> assign(String number, String? pin) async {
    authorizeAssign();
    if (pin != null) {
      final error = validate(pin);
      if (error != null) throw PinRuleError(error);
    }
    final random = _random();
    final salt = Uint8List.fromList(
      List.generate(16, (_) => random.nextInt(256)),
    );
    final hash = pin == null ? null : await _derive(pin, salt, iterations);
    final db = await database.open();
    await db.transaction((txn) async {
      authorizeAssign();
      final employees = await txn.query(
        'employees',
        columns: ['number'],
        where: 'number = ?',
        whereArgs: [number],
      );
      if (employees.isEmpty) {
        throw const PinRuleError('El empleado ya no existe.');
      }
      await txn.delete(
        'employee_pins',
        where: 'employee_number = ?',
        whereArgs: [number],
      );
      if (hash != null) {
        await txn.insert('employee_pins', {
          'employee_number': number,
          'salt': salt,
          'pin_hash': Uint8List.fromList(hash),
          'iterations': iterations,
          'updated_at': _clock().toUtc().millisecondsSinceEpoch,
        });
      }
      await writeAudit(
        txn,
        action: hash == null ? AuditAction.pinRemoved : AuditAction.pinAssigned,
        actor: actor?.call() ?? 'Administrador',
        details: {'employeeNumber': number},
      );
    });
  }

  /// Comprueba número y PIN. El mensaje de error no dice cuál de los dos falló.
  Future<PinCheck> verify(String number, String pin) async {
    const wrong = PinRuleError('Número o PIN incorrecto.');
    final normalized = number.trim();
    final db = await database.open();
    final rows = await db.rawQuery(
      '''
      SELECT p.*, e.name FROM employee_pins p
      JOIN employees e ON e.number = p.employee_number
      WHERE p.employee_number = ?
      ''',
      [normalized],
    );
    if (rows.isEmpty) throw wrong;
    final row = rows.single;
    final now = _clock().toUtc();
    final lockedUntil = row['locked_until'] as int;
    if (lockedUntil > now.millisecondsSinceEpoch) {
      final minutes = ((lockedUntil - now.millisecondsSinceEpoch) / 60000)
          .ceil();
      throw PinRuleError(
        'PIN bloqueado por intentos fallidos. Intenta en $minutes min o pide apoyo a RH.',
      );
    }
    final actual = await _derive(
      pin,
      row['salt'] as Uint8List,
      row['iterations'] as int,
    );
    final correct = PasswordHasher.equal(actual, row['pin_hash'] as Uint8List);
    if (correct) {
      await db.update(
        'employee_pins',
        {'failed_attempts': 0, 'locked_until': 0},
        where: 'employee_number = ?',
        whereArgs: [normalized],
      );
      return PinCheck._(normalized, row['name'] as String, now);
    }
    final failed = (row['failed_attempts'] as int) + 1;
    final lock = failed >= maxAttempts;
    await db.transaction((txn) async {
      await txn.update(
        'employee_pins',
        {
          'failed_attempts': lock ? 0 : failed,
          'locked_until': lock
              ? now.add(lockDuration).millisecondsSinceEpoch
              : 0,
        },
        where: 'employee_number = ?',
        whereArgs: [normalized],
      );
      if (lock) {
        await writeAudit(
          txn,
          action: AuditAction.pinLocked,
          actor: 'checador',
          time: now,
          details: {'employeeNumber': normalized},
        );
      }
    });
    if (lock) {
      throw const PinRuleError(
        'PIN bloqueado 15 minutos por intentos fallidos. Pide apoyo a RH.',
      );
    }
    throw wrong;
  }
}
