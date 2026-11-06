import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../database/local_database.dart';
import '../payroll/payroll.dart' show formatMoney;

enum AuditAction {
  faceEnrolled('face_enrolled', 'Rostro registrado'),
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
  employeeDepartmentChanged(
    'employee_department_changed',
    'Departamento de empleado cambiado',
  ),
  departmentCreated('department_created', 'Departamento creado'),
  departmentUpdated('department_updated', 'Horario de departamento cambiado'),
  holidayAdded('holiday_added', 'Día festivo agregado'),
  holidayRemoved('holiday_removed', 'Día festivo eliminado'),
  consentRecorded('consent_recorded', 'Consentimiento documentado'),
  consentRevoked('consent_revoked', 'Consentimiento revocado'),
  attendanceReviewed('attendance_reviewed', 'Checada manual revisada'),
  pinAssigned('pin_assigned', 'PIN de empleado asignado'),
  pinRemoved('pin_removed', 'PIN de empleado eliminado'),
  pinLocked('pin_locked', 'PIN bloqueado por intentos fallidos'),
  employeeWageChanged('employee_wage_changed', 'Salario de empleado cambiado'),
  payrollPolicyChanged(
    'payroll_policy_changed',
    'Reglas de pre-nómina cambiadas',
  ),
  payrollClosed('payroll_closed', 'Periodo de pre-nómina cerrado'),
  payrollReopened('payroll_reopened', 'Periodo de pre-nómina reabierto'),
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
      case AuditAction.faceEnrolled:
        return 'Rostro asociado al empleado: ${details['employeeNumber']}';
      case AuditAction.employeeCreated:
        return 'Número de empleado: ${details['employeeNumber']}';
      case AuditAction.employeeDepartmentChanged:
        return 'Empleado ${details['employeeNumber']}: ${details['before'] ?? 'sin departamento'} → ${details['after']}';
      case AuditAction.departmentCreated:
      case AuditAction.departmentUpdated:
        final wage = details['dailyWage'];
        return '${details['name']}: ${details['entry']} a ${details['exit']}, tolerancia ${details['tolerance']} min${wage is int ? ', ${formatMoney(wage)} diarios' : ''}';
      case AuditAction.employeeWageChanged:
        final wage = details['dailyWage'];
        return 'Empleado ${details['employeeNumber']}: ${wage is int ? '${formatMoney(wage)} diarios' : 'usa el salario de su departamento'}';
      case AuditAction.payrollPolicyChanged:
        return '${details['period']} · ${details['paidDays']} días pagados · falta = ${details['absenceDays']} días · ${details['latesPerAbsence'] == 0 ? 'retardos sin descuento' : '${details['latesPerAbsence']} retardos = 1 falta'}';
      case AuditAction.payrollClosed:
        final total = details['total'];
        return '${details['start']} al ${details['end']} · ${details['employees']} empleados${total is int ? ' · ${formatMoney(total)}' : ''}';
      case AuditAction.payrollReopened:
        return '${details['start']} al ${details['end']} · ${details['reason']}';
      case AuditAction.holidayAdded:
      case AuditAction.holidayRemoved:
        return '${details['day']} · ${details['name']} · ${details['scope'] ?? 'Toda la empresa'}';
      case AuditAction.pinAssigned:
        return 'Se asignó un PIN al empleado ${details['employeeNumber']}.';
      case AuditAction.pinRemoved:
        return 'Se quitó el PIN del empleado ${details['employeeNumber']}.';
      case AuditAction.pinLocked:
        return 'PIN del empleado ${details['employeeNumber']} bloqueado 15 minutos.';
      case AuditAction.consentRecorded:
        return 'Se registró el folio del consentimiento de ${details['employeeNumber']}.';
      case AuditAction.consentRevoked:
        return 'Se registró la revocación de ${details['employeeNumber']}.';
      case AuditAction.attendanceReviewed:
        return 'Checada ${details['eventId']}: ${details['decision'] == 'approved' ? 'aprobada' : 'rechazada'}.';
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
