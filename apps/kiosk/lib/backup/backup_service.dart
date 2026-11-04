import '../audit/audit_store.dart';
import '../database/local_database.dart';
import 'backup_snapshot.dart';

class BackupExport {
  BackupExport._(this.snapshot, this._record);
  final BackupSnapshot snapshot;
  final Future<void> Function() _record;
  Future<void>? _confirmation;

  Future<void> confirmSaved() => _confirmation ??= _record();
}

class BackupService {
  BackupService(this.database, {required this.authorize, this.actor});
  final LocalDatabase database;
  final void Function() authorize;
  final String Function()? actor;

  Future<BackupSnapshot> capture() async {
    authorize();
    final db = await database.open();
    return db.transaction((txn) async {
      authorize();
      return BackupSnapshot.fromRows(
        createdAt: DateTime.now(),
        departments: await txn.query('departments', orderBy: 'id'),
        employees: await txn.query('employees', orderBy: 'id'),
        events: await txn.query('attendance_events', orderBy: 'id'),
        reviews: await txn.query('attendance_reviews', orderBy: 'id'),
        consentRecords: await txn.query('consent_records', orderBy: 'id'),
      );
    });
  }

  Future<BackupExport> prepareExport() async {
    authorize();
    final name = actor?.call() ?? 'Administrador';
    final snapshot = await capture();
    return BackupExport._(snapshot, () async {
      final db = await database.open();
      await writeAudit(
        db,
        action: AuditAction.backupExported,
        actor: name,
        details: {
          'employees': snapshot.employees.length,
          'attendance': snapshot.events.length,
        },
      );
    });
  }

  Future<void> restore(BackupSnapshot snapshot) async {
    authorize();
    final db = await database.open();
    await db.transaction((txn) async {
      authorize();
      final name = actor?.call() ?? 'Administrador';
      final faces = await txn.query(
        'face_templates',
        columns: ['id'],
        limit: 1,
      );
      if (faces.isNotEmpty) {
        throw const InvalidBackup(
          'Esta tablet tiene rostros registrados. La restauración está bloqueada para conservarlos.',
        );
      }
      await txn.delete('attendance_reviews');
      await txn.delete('consent_records');
      await txn.delete('attendance_events');
      await txn.delete('employees');
      await txn.delete('departments');
      final batch = txn.batch();
      for (final row in snapshot.departments) {
        batch.insert('departments', row);
      }
      for (final row in snapshot.employees) {
        batch.insert('employees', row);
      }
      for (final row in snapshot.events) {
        batch.insert('attendance_events', row);
      }
      for (final row in snapshot.reviews) {
        batch.insert('attendance_reviews', row);
      }
      for (final row in snapshot.consentRecords) {
        batch.insert('consent_records', row);
      }
      await batch.commit(noResult: true);
      await writeAudit(
        txn,
        action: AuditAction.backupRestored,
        actor: name,
        details: {
          'employees': snapshot.employees.length,
          'attendance': snapshot.events.length,
        },
      );
    });
  }
}
