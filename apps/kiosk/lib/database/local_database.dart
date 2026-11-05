import 'dart:convert';

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
        version: 12,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) async {
          await _createDepartments(db);
          await db.execute('''
            CREATE TABLE employees (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              number TEXT NOT NULL UNIQUE CHECK(length(trim(number)) BETWEEN 1 AND 30),
              name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 120),
              department_id INTEGER REFERENCES departments(id),
              registered_at INTEGER
            )
          ''');
          await _createAttendance(db);
          await _createAdmin(db);
          await _createAudit(db);
          await _createRhAccounts(db);
          await _createOrganization(db);
          await _createAttendanceReviews(db);
          await _createConsentRecords(db);
          await _createFaceTemplates(db);
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
          if (oldVersion < 6) {
            await _createRhAccounts(db);
          }
          if (oldVersion < 7) {
            await _createOrganization(db);
          }
          if (oldVersion < 8) {
            await _createAttendanceReviews(db);
          }
          if (oldVersion < 9) {
            await _createConsentRecords(db);
          }
          if (oldVersion < 10) {
            await _createFaceTemplates(db);
            if (oldVersion >= 2) {
              await db.execute(
                "ALTER TABLE attendance_events ADD COLUMN capture_method TEXT NOT NULL DEFAULT 'manual'",
              );
              await db.execute(
                'ALTER TABLE attendance_events ADD COLUMN similarity REAL',
              );
              await db.execute(
                'ALTER TABLE attendance_events ADD COLUMN identity_model TEXT',
              );
              await db.execute(
                'ALTER TABLE attendance_events ADD COLUMN liveness_method TEXT',
              );
            }
          }
          if (oldVersion < 11) {
            await _createDepartments(db);
            await db.execute(
              'ALTER TABLE employees ADD COLUMN department_id INTEGER REFERENCES departments(id)',
            );
            if (oldVersion >= 2) {
              await db.execute(
                'ALTER TABLE attendance_events ADD COLUMN schedule_note TEXT',
              );
            }
          }
          if (oldVersion == 11) {
            await db.execute(
              'ALTER TABLE departments ADD COLUMN work_days INTEGER NOT NULL DEFAULT 31 CHECK(work_days BETWEEN 1 AND 127)',
            );
          }
          if (oldVersion < 12) {
            await db.execute(
              'ALTER TABLE employees ADD COLUMN registered_at INTEGER',
            );
            await _backfillRegistration(db);
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
        occurred_at INTEGER NOT NULL,
        capture_method TEXT NOT NULL DEFAULT 'manual',
        similarity REAL,
        identity_model TEXT,
        liveness_method TEXT,
        schedule_note TEXT
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

  static Future<void> _createRhAccounts(Database db) async {
    await db.execute('''
      CREATE TABLE rh_accounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL UNIQUE COLLATE NOCASE,
        salt BLOB NOT NULL,
        password_hash BLOB NOT NULL,
        algorithm TEXT NOT NULL,
        iterations INTEGER NOT NULL,
        failed_attempts INTEGER NOT NULL DEFAULT 0,
        locked_until INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  static Future<void> _createOrganization(Database db) async {
    await db.execute('''
      CREATE TABLE organization (
        id INTEGER PRIMARY KEY CHECK(id = 1),
        name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 2 AND 120)
      )
    ''');
  }

  static Future<void> _createAttendanceReviews(Database db) async {
    await db.execute('''
      CREATE TABLE attendance_reviews (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        event_id INTEGER NOT NULL REFERENCES attendance_events(id),
        decision TEXT NOT NULL CHECK(decision IN ('approved', 'rejected')),
        reviewer TEXT NOT NULL CHECK(length(trim(reviewer)) BETWEEN 3 AND 100),
        reason TEXT NOT NULL CHECK(length(trim(reason)) BETWEEN 10 AND 500),
        reviewed_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX attendance_reviews_event_id ON attendance_reviews(event_id, id)',
    );
  }

  static Future<void> _createConsentRecords(Database db) async {
    await db.execute('''
      CREATE TABLE consent_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_number TEXT NOT NULL REFERENCES employees(number),
        kind TEXT NOT NULL CHECK(kind IN ('recorded', 'revoked')),
        document_reference TEXT NOT NULL CHECK(length(trim(document_reference)) BETWEEN 5 AND 120),
        actor TEXT NOT NULL CHECK(length(trim(actor)) BETWEEN 3 AND 100),
        occurred_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX consent_records_employee_id
      ON consent_records(employee_number, id)
    ''');
  }

  Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening != null) {
      await (await opening).close();
    }
  }

  /// Horario por departamento, en minutos desde la medianoche. Si la salida es
  /// menor que la entrada, el turno cruza la medianoche.
  static Future<void> _createDepartments(Database db) async {
    await db.execute('''
      CREATE TABLE departments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE COLLATE NOCASE CHECK(length(trim(name)) BETWEEN 2 AND 80),
        entry_minutes INTEGER NOT NULL CHECK(entry_minutes BETWEEN 0 AND 1439),
        exit_minutes INTEGER NOT NULL CHECK(exit_minutes BETWEEN 0 AND 1439),
        tolerance_minutes INTEGER NOT NULL DEFAULT 10 CHECK(tolerance_minutes BETWEEN 0 AND 240),
        work_days INTEGER NOT NULL DEFAULT 31 CHECK(work_days BETWEEN 1 AND 127),
        CHECK(entry_minutes <> exit_minutes)
      )
    ''');
  }

  /// Fecha de alta de los empleados que ya existían, tomada de la bitácora.
  /// Sin registro en la bitácora queda vacía y el reporte cuenta todo el periodo.
  static Future<void> _backfillRegistration(Database db) async {
    final tables = await db.query(
      'sqlite_master',
      where: "type = 'table' AND name = 'audit_entries'",
    );
    if (tables.isEmpty) return;
    final rows = await db.query(
      'audit_entries',
      columns: ['occurred_at', 'details'],
      where: 'action = ?',
      whereArgs: ['employee_created'],
      orderBy: 'id',
    );
    final first = <String, int>{};
    for (final row in rows) {
      try {
        final details = jsonDecode(row['details'] as String);
        final number = details is Map ? details['employeeNumber'] : null;
        if (number is String) {
          first.putIfAbsent(number, () => row['occurred_at'] as int);
        }
      } on FormatException {
        // Registro ilegible: se omite.
      }
    }
    for (final entry in first.entries) {
      await db.update(
        'employees',
        {'registered_at': entry.value},
        where: 'number = ? AND registered_at IS NULL',
        whereArgs: [entry.key],
      );
    }
  }

  static Future<void> _createFaceTemplates(Database db) async {
    await db.execute('''
      CREATE TABLE face_templates (
        id TEXT PRIMARY KEY,
        employee_number TEXT NOT NULL UNIQUE REFERENCES employees(number),
        consent_id INTEGER NOT NULL REFERENCES consent_records(id),
        model_id TEXT NOT NULL,
        encrypted_template BLOB NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
  }
}
