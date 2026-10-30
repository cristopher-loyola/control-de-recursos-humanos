import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

class LocalDatabase {
  LocalDatabase({this.name = 'kiosk.db', this.filePath, this.factory});
  final String name;
  final String? filePath;
  final DatabaseFactory? factory;
  Future<Database>? _opening;

  Future<Database> open() async {
    try {
      return await (_opening ??= _open());
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  Future<Database> _open() async {
    final selectedFactory = factory ?? databaseFactory;
    return selectedFactory.openDatabase(
      filePath ?? path.join(await selectedFactory.getDatabasesPath(), name),
      options: OpenDatabaseOptions(
        version: 5,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE employees (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              number TEXT NOT NULL UNIQUE CHECK(length(trim(number)) BETWEEN 1 AND 30),
              name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 120)
            )
          ''');
          await _createAttendance(db);
          await _createAdmin(db);
          await _createAudit(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await _createAttendance(db);
          }
          if (oldVersion < 3) {
            await _createAdmin(db);
          }
          if (oldVersion < 4) {
            await _createAudit(db);
          }
          if (oldVersion >= 3 && oldVersion < 5) {
            await db.execute(
              'ALTER TABLE administrator ADD COLUMN recovery_salt BLOB',
            );
            await db.execute(
              'ALTER TABLE administrator ADD COLUMN recovery_hash BLOB',
            );
          }
        },
      ),
    );
  }

  static Future<void> _createAttendance(Database db) async {
    await db.execute('''
      CREATE TABLE attendance_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_number TEXT NOT NULL REFERENCES employees(number),
        kind TEXT NOT NULL CHECK(kind IN ('entry', 'exit')),
        occurred_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX attendance_employee_id ON attendance_events(employee_number, id)',
    );
    await db.execute(
      'CREATE INDEX attendance_occurred_at ON attendance_events(occurred_at)',
    );
  }

  static Future<void> _createAdmin(Database db) async {
    await db.execute('''
      CREATE TABLE administrator (
        id INTEGER PRIMARY KEY CHECK(id = 1),
        username TEXT NOT NULL,
        salt BLOB NOT NULL,
        password_hash BLOB NOT NULL,
        algorithm TEXT NOT NULL,
        iterations INTEGER NOT NULL,
        failed_attempts INTEGER NOT NULL DEFAULT 0,
        locked_until INTEGER NOT NULL DEFAULT 0,
        recovery_salt BLOB,
        recovery_hash BLOB
      )
    ''');
  }

  static Future<void> _createAudit(Database db) async {
    await db.execute('''
      CREATE TABLE audit_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        occurred_at INTEGER NOT NULL,
        action TEXT NOT NULL,
        actor TEXT,
        details TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TRIGGER audit_no_update BEFORE UPDATE ON audit_entries
      BEGIN SELECT RAISE(ABORT, 'Audit entries cannot be edited'); END
    ''');
    await db.execute('''
      CREATE TRIGGER audit_no_delete BEFORE DELETE ON audit_entries
      BEGIN SELECT RAISE(ABORT, 'Audit entries cannot be deleted'); END
    ''');
  }

  Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening != null) {
      await (await opening).close();
    }
  }
}
