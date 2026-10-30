import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../database/local_database.dart';
import '../audit/audit_store.dart';
import 'password_hasher.dart';

class AdminAccessRequired implements Exception {}

class AuthenticationError implements Exception {
  const AuthenticationError(this.message);
  final String message;
}

String? validateAdminUsername(String? value) {
  if (!RegExp(r'^[a-zA-Z0-9._-]{3,40}$').hasMatch(value?.trim() ?? '')) {
    return 'Usa de 3 a 40 letras, números, puntos, guiones o guiones bajos.';
  }
  return null;
}

String? validateAdminPassword(String? value) {
  final password = value ?? '';
  if (password.length < 12 ||
      password.length > 128 ||
      password.trim().isEmpty) {
    return 'Usa una contraseña de 12 a 128 caracteres.';
  }
  return null;
}

class AdminAuth extends ChangeNotifier {
  AdminAuth(this.database, {PasswordHasher? hasher, DateTime Function()? clock})
    : _hasher = hasher ?? const PasswordHasher(),
      _clock = clock ?? DateTime.now;
  final LocalDatabase database;
  final PasswordHasher _hasher;
  final DateTime Function() _clock;
  bool _configured = false;
  String? _accountName;
  bool _authenticated = false;
  bool _busy = false;
  bool _disposed = false;
  DateTime? _expiresAt;
  Timer? _timer;
  static const idleDuration = Duration(minutes: 10);

  bool get configured => _configured;
  bool get isAuthenticated => _authenticated;
  String get administratorName {
    requireAdmin();
    return _accountName!;
  }

  Future<void> initialize() async {
    final rows = await (await database.open()).query(
      'administrator',
      columns: ['id'],
      limit: 1,
    );
    _configured = rows.isNotEmpty;
  }

  Future<void> create(String username, String password) async {
    _begin();
    try {
      final validation =
          validateAdminUsername(username) ?? validateAdminPassword(password);
      if (validation != null) {
        throw AuthenticationError(validation);
      }
      final db = await database.open();
      if ((await db.query(
        'administrator',
        columns: ['id'],
        limit: 1,
      )).isNotEmpty) {
        throw const AuthenticationError(
          'El administrador ya está configurado. Inicia sesión.',
        );
      }
      final random = Random.secure();
      final salt = Uint8List.fromList(
        List.generate(16, (_) => random.nextInt(256)),
      );
      final hash = Uint8List.fromList(await _hasher.derive(password, salt));
      await db.transaction((txn) async {
        if ((await txn.query(
          'administrator',
          columns: ['id'],
          limit: 1,
        )).isNotEmpty) {
          throw const AuthenticationError(
            'El administrador ya está configurado.',
          );
        }
        await writeAudit(
          txn,
          action: AuditAction.administratorCreated,
          actor: username.trim().toLowerCase(),
          time: _clock(),
        );
        await txn.insert('administrator', {
          'id': 1,
          'username': username.trim().toLowerCase(),
          'salt': salt,
          'password_hash': hash,
          'algorithm': PasswordHasher.algorithm,
          'iterations': PasswordHasher.iterations,
        });
      });
      _configured = true;
      _accountName = username.trim().toLowerCase();
      _grant();
    } finally {
      _busy = false;
    }
  }

  Future<void> login(String username, String password) async {
    _begin();
    try {
      if (password.length > 128 || username.length > 100) {
        throw const AuthenticationError('Usuario o contraseña incorrectos.');
      }
      final db = await database.open();
      final rows = await db.query('administrator', where: 'id = 1');
      if (rows.isEmpty) {
        throw const AuthenticationError('Primero configura el administrador.');
      }
      final row = rows.single;
      final lockedUntil = row['locked_until'] as int;
      if (lockedUntil > _clock().millisecondsSinceEpoch) {
        throw const AuthenticationError(
          'Demasiados intentos. Espera un minuto y vuelve a intentarlo.',
        );
      }
      if (row['algorithm'] != PasswordHasher.algorithm ||
          row['iterations'] != PasswordHasher.iterations) {
        throw const AuthenticationError(
          'No se pudo verificar la configuración de acceso.',
        );
      }
      final salt = (row['salt'] as List).cast<int>();
      final expected = (row['password_hash'] as List).cast<int>();
      if (salt.length != 16 || expected.length != 32) {
        throw const AuthenticationError(
          'No se pudo verificar la configuración de acceso.',
        );
      }
      final actual = await _hasher.derive(password, salt);
      final correct = PasswordHasher.equal(actual, expected);
      if (!correct || username.trim().toLowerCase() != row['username']) {
        final attempts =
            (lockedUntil != 0 ? 0 : row['failed_attempts'] as int) + 1;
        await db.update('administrator', {
          'failed_attempts': attempts,
          'locked_until': attempts >= 5
              ? _clock().add(const Duration(minutes: 1)).millisecondsSinceEpoch
              : 0,
        }, where: 'id = 1');
        await writeAudit(
          db,
          action: AuditAction.loginFailed,
          time: _clock(),
          details: {'blocked': attempts >= 5},
        );
        throw AuthenticationError(
          attempts >= 5
              ? 'Demasiados intentos. Espera un minuto y vuelve a intentarlo.'
              : 'Usuario o contraseña incorrectos.',
        );
      }
      await db.update('administrator', {
        'failed_attempts': 0,
        'locked_until': 0,
      }, where: 'id = 1');
      _configured = true;
      _accountName = row['username'] as String;
      await writeAudit(
        db,
        action: AuditAction.loginSucceeded,
        actor: _accountName,
        time: _clock(),
      );
      _grant();
    } finally {
      _busy = false;
    }
  }

  void _begin() {
    if (_busy || _disposed) {
      throw const AuthenticationError(
        'Espera a que termine la operación actual.',
      );
    }
    _busy = true;
  }

  void _grant() {
    if (_disposed) {
      return;
    }
    _authenticated = true;
    _expiresAt = _clock().add(idleDuration);
    _timer?.cancel();
    _timer = Timer(idleDuration, logout);
    notifyListeners();
  }

  void touch() {
    if (!_authenticated) {
      return;
    }
    if (!_clock().isBefore(_expiresAt!)) {
      logout();
      return;
    }
    _expiresAt = _clock().add(idleDuration);
    _timer?.cancel();
    _timer = Timer(idleDuration, logout);
  }

  void requireAdmin() {
    if (!_authenticated ||
        _expiresAt == null ||
        !_clock().isBefore(_expiresAt!)) {
      logout();
      throw AdminAccessRequired();
    }
  }

  void logout() {
    _timer?.cancel();
    _expiresAt = null;
    final changed = _authenticated;
    _authenticated = false;
    if (changed && !_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
