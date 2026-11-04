import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../database/local_database.dart';
import '../audit/audit_store.dart';
import 'password_hasher.dart';

class AdminAccessRequired implements Exception {}

enum LocalRole { administrator, humanResources }

class AuthenticationError implements Exception {
  const AuthenticationError(this.message);
  final String message;
}

Uint8List _newSalt() {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
}

String _newRecoveryCode() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 16)}-${hex.substring(16, 24)}-${hex.substring(24)}'
      .toUpperCase();
}

String _normalizeRecoveryCode(String value) =>
    value.replaceAll(RegExp(r'[\s-]'), '').toLowerCase();

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
  bool _organizationConfigured = false;
  String? _accountName;
  bool _authenticated = false;
  LocalRole? _role;
  bool _busy = false;
  bool _disposed = false;
  String? _pendingRecoveryCode;
  DateTime? _expiresAt;
  Timer? _timer;
  static const idleDuration = Duration(minutes: 10);

  bool get configured => _configured;
  bool get organizationConfigured => _organizationConfigured;
  String? _organizationName;
  String? get organizationName => _organizationName;

  /// Nombre de la cuenta con sesión abierta, sin exigir permisos (para mostrarlo).
  String? get signedInName => _authenticated ? _accountName : null;
  bool get isAuthenticated => _authenticated;
  bool get isAdministrator =>
      _authenticated && _role == LocalRole.administrator;
  bool get isHumanResources =>
      _authenticated && _role == LocalRole.humanResources;
  String get accountName {
    requireStaff();
    return _accountName!;
  }

  String? get pendingRecoveryCode => _pendingRecoveryCode;

  void acknowledgeRecoveryCode() {
    if (_pendingRecoveryCode == null) return;
    _pendingRecoveryCode = null;
    if (!_disposed) notifyListeners();
  }

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
    final organizations = await (await database.open()).query(
      'organization',
      columns: ['id', 'name'],
      limit: 1,
    );
    _organizationConfigured = organizations.isNotEmpty;
    _organizationName = organizations.isEmpty
        ? null
        : organizations.single['name'] as String?;
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
      final recoveryCode = _newRecoveryCode();
      final recoverySalt = _newSalt();
      final recoveryHash = Uint8List.fromList(
        await _hasher.derive(
          _normalizeRecoveryCode(recoveryCode),
          recoverySalt,
        ),
      );
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
          'recovery_salt': recoverySalt,
          'recovery_hash': recoveryHash,
        });
      });
      _configured = true;
      _accountName = username.trim().toLowerCase();
      _role = LocalRole.administrator;
      _pendingRecoveryCode = recoveryCode;
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
      final rhRows = await db.query(
        'rh_accounts',
        where: 'username = ? COLLATE NOCASE',
        whereArgs: [username.trim()],
        limit: 1,
      );
      if (rhRows.isNotEmpty) {
        await _loginRh(db, rhRows.single, password);
        return;
      }
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
      _role = LocalRole.administrator;
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

  Future<void> _loginRh(
    Database db,
    Map<String, Object?> row,
    String password,
  ) async {
    final now = _clock();
    final lockedUntil = row['locked_until'] as int;
    if (lockedUntil > now.millisecondsSinceEpoch) {
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
    if (!PasswordHasher.equal(actual, expected)) {
      final attempts =
          (lockedUntil != 0 ? 0 : row['failed_attempts'] as int) + 1;
      await db.transaction((txn) async {
        await txn.update(
          'rh_accounts',
          {
            'failed_attempts': attempts,
            'locked_until': attempts >= 5
                ? now.add(const Duration(minutes: 1)).millisecondsSinceEpoch
                : 0,
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        await writeAudit(
          txn,
          action: AuditAction.loginFailed,
          details: {'role': 'rh', 'blocked': attempts >= 5},
          time: now,
        );
      });
      throw AuthenticationError(
        attempts >= 5
            ? 'Demasiados intentos. Espera un minuto y vuelve a intentarlo.'
            : 'Usuario o contraseña incorrectos.',
      );
    }
    await db.transaction((txn) async {
      await txn.update(
        'rh_accounts',
        {'failed_attempts': 0, 'locked_until': 0},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      await writeAudit(
        txn,
        action: AuditAction.loginSucceeded,
        actor: row['username'] as String,
        details: {'role': 'rh'},
        time: now,
      );
    });
    _configured = true;
    _accountName = row['username'] as String;
    _role = LocalRole.humanResources;
    _grant();
  }

  Future<void> saveOrganization(String name) async {
    requireAdmin();
    _begin();
    try {
      final normalized = name.trim();
      if (normalized.length < 2 || normalized.length > 120) {
        throw const AuthenticationError(
          'Escribe un nombre de 2 a 120 caracteres.',
        );
      }
      final db = await database.open();
      await db.transaction((txn) async {
        await txn.insert('organization', {
          'id': 1,
          'name': normalized,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await writeAudit(
          txn,
          action: AuditAction.organizationConfigured,
          actor: _accountName,
          time: _clock(),
        );
      });
      _organizationConfigured = true;
      _organizationName = normalized;
      if (!_disposed) notifyListeners();
    } finally {
      _busy = false;
    }
  }

  Future<void> createRhAccount(String username, String password) async {
    requireAdmin();
    if (!_organizationConfigured) {
      throw const AuthenticationError('Configura primero la organización.');
    }
    _begin();
    try {
      final validation =
          validateAdminUsername(username) ?? validateAdminPassword(password);
      if (validation != null) throw AuthenticationError(validation);
      final normalized = username.trim().toLowerCase();
      final db = await database.open();
      final administrator = await db.query(
        'administrator',
        columns: ['username'],
        where: 'id = 1',
      );
      if (administrator.isNotEmpty &&
          administrator.single['username'] == normalized) {
        throw const AuthenticationError('Ese usuario ya existe.');
      }
      final salt = _newSalt();
      final hash = Uint8List.fromList(await _hasher.derive(password, salt));
      try {
        await db.transaction((txn) async {
          await txn.insert('rh_accounts', {
            'username': normalized,
            'salt': salt,
            'password_hash': hash,
            'algorithm': PasswordHasher.algorithm,
            'iterations': PasswordHasher.iterations,
          });
          await writeAudit(
            txn,
            action: AuditAction.rhAccountCreated,
            actor: _accountName,
            details: {'username': normalized},
            time: _clock(),
          );
        });
      } on DatabaseException catch (error) {
        if (error.isUniqueConstraintError()) {
          throw const AuthenticationError('Ese usuario ya existe.');
        }
        rethrow;
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> rotateRecoveryCode() async {
    requireAdmin();
    _begin();
    try {
      final code = _newRecoveryCode();
      final salt = _newSalt();
      final hash = Uint8List.fromList(
        await _hasher.derive(_normalizeRecoveryCode(code), salt),
      );
      final db = await database.open();
      await db.transaction((txn) async {
        await txn.update('administrator', {
          'recovery_salt': salt,
          'recovery_hash': hash,
        }, where: 'id = 1');
        await writeAudit(
          txn,
          action: AuditAction.recoveryCodeRotated,
          actor: _accountName,
          time: _clock(),
        );
      });
      _pendingRecoveryCode = code;
      if (!_disposed) notifyListeners();
    } finally {
      _busy = false;
    }
  }

  Future<void> recover(String code, String newPassword) async {
    _begin();
    try {
      final validation = validateAdminPassword(newPassword);
      if (validation != null) throw AuthenticationError(validation);
      final db = await database.open();
      final rows = await db.query('administrator', where: 'id = 1');
      if (rows.isEmpty) {
        throw const AuthenticationError('No se pudo recuperar el acceso.');
      }
      final row = rows.single;
      final now = _clock();
      final lockedUntil = row['locked_until'] as int;
      if (lockedUntil > now.millisecondsSinceEpoch) {
        throw const AuthenticationError(
          'Demasiados intentos. Espera un minuto y vuelve a intentarlo.',
        );
      }
      final normalized = _normalizeRecoveryCode(code);
      final savedSalt = (row['recovery_salt'] as List?)?.cast<int>();
      final savedHash = (row['recovery_hash'] as List?)?.cast<int>();
      final validFormat = RegExp(r'^[0-9a-f]{32}$').hasMatch(normalized);
      final validStored = savedSalt?.length == 16 && savedHash?.length == 32;
      final actual = validFormat && validStored
          ? await _hasher.derive(normalized, savedSalt!)
          : <int>[];
      if (!validFormat ||
          !validStored ||
          !PasswordHasher.equal(actual, savedHash!)) {
        final attempts =
            (lockedUntil != 0 ? 0 : row['failed_attempts'] as int) + 1;
        await db.transaction((txn) async {
          await txn.update('administrator', {
            'failed_attempts': attempts,
            'locked_until': attempts >= 5
                ? now.add(const Duration(minutes: 1)).millisecondsSinceEpoch
                : 0,
          }, where: 'id = 1');
          await writeAudit(
            txn,
            action: AuditAction.passwordRecoveryFailed,
            details: {'blocked': attempts >= 5},
            time: now,
          );
        });
        throw AuthenticationError(
          attempts >= 5
              ? 'Demasiados intentos. Espera un minuto y vuelve a intentarlo.'
              : 'Código de recuperación incorrecto.',
        );
      }
      final passwordSalt = _newSalt();
      final passwordHash = Uint8List.fromList(
        await _hasher.derive(newPassword, passwordSalt),
      );
      final replacementCode = _newRecoveryCode();
      final replacementSalt = _newSalt();
      final replacementHash = Uint8List.fromList(
        await _hasher.derive(
          _normalizeRecoveryCode(replacementCode),
          replacementSalt,
        ),
      );
      await db.transaction((txn) async {
        await txn.update('administrator', {
          'salt': passwordSalt,
          'password_hash': passwordHash,
          'recovery_salt': replacementSalt,
          'recovery_hash': replacementHash,
          'failed_attempts': 0,
          'locked_until': 0,
        }, where: 'id = 1');
        await writeAudit(
          txn,
          action: AuditAction.passwordRecovered,
          actor: row['username'] as String,
          time: now,
        );
      });
      _accountName = row['username'] as String;
      _configured = true;
      _pendingRecoveryCode = replacementCode;
      _role = LocalRole.administrator;
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

  void requireStaff() {
    if (!_authenticated ||
        _expiresAt == null ||
        !_clock().isBefore(_expiresAt!)) {
      logout();
      throw AdminAccessRequired();
    }
  }

  void requireAdmin() {
    requireStaff();
    if (_role != LocalRole.administrator) {
      throw AdminAccessRequired();
    }
  }

  void logout() {
    _timer?.cancel();
    _expiresAt = null;
    final changed = _authenticated;
    _authenticated = false;
    _role = null;
    _pendingRecoveryCode = null;
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
