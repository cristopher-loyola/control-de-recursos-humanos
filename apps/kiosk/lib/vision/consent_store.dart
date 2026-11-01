import '../audit/audit_store.dart';
import '../database/local_database.dart';

enum ConsentKind {
  recorded('recorded'),
  revoked('revoked');

  const ConsentKind(this.value);
  final String value;
}

class ConsentRuleError implements Exception {
  const ConsentRuleError(this.message);
  final String message;
}

class ConsentItem {
  const ConsentItem({
    required this.employeeNumber,
    required this.employeeName,
    this.kind,
    this.documentReference,
    this.actor,
    this.occurredAt,
  });

  final String employeeNumber;
  final String employeeName;
  final ConsentKind? kind;
  final String? documentReference;
  final String? actor;
  final DateTime? occurredAt;

  bool get active => kind == ConsentKind.recorded;

  factory ConsentItem.fromRow(Map<String, Object?> row) {
    final kind = row['kind'] as String?;
    final occurredAt = row['occurred_at'] as int?;
    return ConsentItem(
      employeeNumber: row['number'] as String,
      employeeName: row['name'] as String,
      kind: kind == null
          ? null
          : ConsentKind.values.firstWhere((value) => value.value == kind),
      documentReference: row['document_reference'] as String?,
      actor: row['actor'] as String?,
      occurredAt: occurredAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(occurredAt, isUtc: true),
    );
  }
}

class ConsentStore {
  ConsentStore(
    this.database, {
    required this.authorize,
    required this.actor,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LocalDatabase database;
  final void Function() authorize;
  final String Function() actor;
  final DateTime Function() _clock;

  Future<List<ConsentItem>> list() async {
    authorize();
    final db = await database.open();
    return db.transaction((txn) async {
      authorize();
      final rows = await txn.rawQuery('''
        SELECT e.number, e.name, c.kind, c.document_reference,
               c.actor, c.occurred_at
        FROM employees e
        LEFT JOIN consent_records c ON c.id = (
          SELECT id FROM consent_records
          WHERE employee_number = e.number ORDER BY id DESC LIMIT 1
        )
        ORDER BY e.name COLLATE NOCASE, e.number
      ''');
      return rows.map(ConsentItem.fromRow).toList();
    });
  }

  Future<void> record(
    String employeeNumber,
    ConsentKind kind,
    String documentReference,
  ) async {
    authorize();
    final reference = documentReference.trim();
    if (reference.length < 5 ||
        reference.length > 120 ||
        reference.contains('\u0000')) {
      throw const ConsentRuleError(
        'Escribe el folio del documento firmado (5 a 120 caracteres).',
      );
    }
    final responsible = actor().trim();
    if (responsible.length < 3 || responsible.length > 100) {
      throw const ConsentRuleError('No se identificó al responsable.');
    }
    final db = await database.open();
    await db.transaction((txn) async {
      authorize();
      final employee = await txn.query(
        'employees',
        columns: ['number'],
        where: 'number = ?',
        whereArgs: [employeeNumber],
        limit: 1,
      );
      if (employee.isEmpty) {
        throw const ConsentRuleError('El empleado ya no está disponible.');
      }
      final previous = await txn.query(
        'consent_records',
        columns: ['kind'],
        where: 'employee_number = ?',
        whereArgs: [employeeNumber],
        orderBy: 'id DESC',
        limit: 1,
      );
      final active =
          previous.isNotEmpty && previous.single['kind'] == 'recorded';
      if (kind == ConsentKind.recorded && active) {
        throw const ConsentRuleError(
          'Ya hay un consentimiento vigente para este empleado.',
        );
      }
      if (kind == ConsentKind.revoked && !active) {
        throw const ConsentRuleError(
          'No hay un consentimiento vigente para revocar.',
        );
      }
      final now = _clock().toUtc();
      await txn.insert('consent_records', {
        'employee_number': employeeNumber,
        'kind': kind.value,
        'document_reference': reference,
        'actor': responsible,
        'occurred_at': now.millisecondsSinceEpoch,
      });
      await writeAudit(
        txn,
        action: kind == ConsentKind.recorded
            ? AuditAction.consentRecorded
            : AuditAction.consentRevoked,
        actor: responsible,
        time: now,
        details: {'employeeNumber': employeeNumber},
      );
    });
  }
}
