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
        version: 2,
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
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await _createAttendance(db);
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

  Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening != null) {
      await (await opening).close();
    }
  }
}
