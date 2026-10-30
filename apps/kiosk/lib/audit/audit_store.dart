import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../database/local_database.dart';

enum AuditAction {
  administratorCreated('administrator_created', 'Administrador configurado'),
  rhAccountCreated('rh_account_created', 'Cuenta de RH creada'),
  organizationConfigured('organization_configured', 'Organización configurada'),
  loginSucceeded('login_succeeded', 'Acceso de administrador'),
  loginFailed('login_failed', 'Intento de acceso rechazado'),
  recoveryCodeRotated(
    'recovery_code_rotated',
    'Código de recuperación renovado',
  ),
  passwordRecoveryFailed(
    'password_recovery_failed',
    'Intento de recuperación rechazado',
  ),
  passwordRecovered('password_recovered', 'Contraseña recuperada'),
  employeeCreated('employee_created', 'Empleado registrado'),
  backupExported('backup_exported', 'Respaldo exportado'),
  backupRestored('backup_restored', 'Respaldo restaurado');

  const AuditAction(this.value, this.label);
  final String value;
  final String label;
}

Future<void> writeAudit(
  DatabaseExecutor db, {
  required AuditAction action,
  String? actor,
  Map<String, Object?> details = const {},
  DateTime? time,
}) async {
  await db.insert('audit_entries', {
    'occurred_at': (time ?? DateTime.now()).toUtc().millisecondsSinceEpoch,
    'action': action.value,
    'actor': actor,
    'details': jsonEncode(details),
  });
}

class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.time,
    required this.action,
    required this.actor,
    required this.details,
  });
  final int id;
  final DateTime time;
  final AuditAction action;
  final String? actor;
  final Map<String, dynamic> details;

  factory AuditEntry.fromRow(Map<String, Object?> row) => AuditEntry(
    id: row['id'] as int,
    time: DateTime.fromMillisecondsSinceEpoch(
      row['occurred_at'] as int,
      isUtc: true,
    ),
    action: AuditAction.values.firstWhere(
      (action) => action.value == row['action'],
    ),
    actor: row['actor'] as String?,
    details: jsonDecode(row['details'] as String) as Map<String, dynamic>,
  );

  String get description {
    switch (action) {
      case AuditAction.employeeCreated:
        return 'Número de empleado: ${details['employeeNumber']}';
      case AuditAction.backupExported:
      case AuditAction.backupRestored:
        return '${details['employees']} empleados · ${details['attendance']} movimientos';
      case AuditAction.loginFailed:
        return details['blocked'] == true
            ? 'Acceso bloqueado temporalmente por intentos fallidos.'
            : 'Credenciales incorrectas.';
      case AuditAction.recoveryCodeRotated:
        return 'Se generó un código de recuperación nuevo.';
      case AuditAction.passwordRecoveryFailed:
        return details['blocked'] == true
            ? 'Recuperación bloqueada temporalmente por intentos fallidos.'
            : 'Código de recuperación incorrecto.';
      case AuditAction.passwordRecovered:
        return 'Contraseña administrativa cambiada con código de recuperación.';
      case AuditAction.administratorCreated:
        return 'Cuenta local creada en esta tablet.';
      case AuditAction.rhAccountCreated:
        return 'Cuenta de RH creada: ${details['username']}';
      case AuditAction.organizationConfigured:
        return 'Organización configurada en esta tablet.';
      case AuditAction.loginSucceeded:
        return 'Sesión administrativa iniciada.';
    }
  }
}

class AuditStore {
  AuditStore(this.database, {required this.authorize});
  final LocalDatabase database;
  final void Function() authorize;
  static const pageSize = 50;

  Future<List<AuditEntry>> list({int? beforeId}) async {
    authorize();
    final db = await database.open();
    return db.transaction((txn) async {
      authorize();
      final rows = await txn.query(
        'audit_entries',
        where: beforeId == null ? null : 'id < ?',
        whereArgs: beforeId == null ? null : [beforeId],
        orderBy: 'id DESC',
        limit: pageSize,
      );
      return rows.map(AuditEntry.fromRow).toList();
    });
  }
}
