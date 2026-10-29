import '../database/local_database.dart';
import 'backup_snapshot.dart';

class BackupService {
  BackupService(this.database);
  final LocalDatabase database;

  Future<BackupSnapshot> capture() async {
    final db = await database.open();
    return db.transaction(
      (txn) async => BackupSnapshot.fromRows(
        createdAt: DateTime.now(),
        employees: await txn.query('employees', orderBy: 'id'),
        events: await txn.query('attendance_events', orderBy: 'id'),
      ),
    );
  }

  Future<void> restore(BackupSnapshot snapshot) async {
    final db = await database.open();
    await db.transaction((txn) async {
      await txn.delete('attendance_events');
      await txn.delete('employees');
      final batch = txn.batch();
      for (final row in snapshot.employees) {
        batch.insert('employees', row);
      }
      for (final row in snapshot.events) {
        batch.insert('attendance_events', row);
      }
      await batch.commit(noResult: true);
    });
  }
}
