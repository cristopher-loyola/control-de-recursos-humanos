import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../audit/audit_store.dart';
import '../database/local_database.dart';
import 'face_engine.dart';
import 'face_matching.dart';

class FaceMatch {
  FaceMatch._(
    this.employeeNumber,
    this.employeeName,
    this.templateId,
    this.consentId,
    this.score,
    this.createdAt,
  );
  final String employeeNumber;
  final String employeeName;
  final String templateId;
  final int consentId;
  final double score;
  final DateTime createdAt;
  bool _used = false;

  void claim(DateTime now) {
    if (_used ||
        now.isBefore(createdAt) ||
        now.difference(createdAt) > const Duration(seconds: 20)) {
      throw const FaceRuleError(
        'La identificación venció. Vuelve a mirar a la cámara.',
      );
    }
    _used = true;
  }
}

class _ActiveFace {
  const _ActiveFace({
    required this.employeeNumber,
    required this.employeeName,
    required this.templateId,
    required this.consentId,
    required this.samples,
  });

  final String employeeNumber;
  final String employeeName;
  final String templateId;
  final int consentId;
  final List<List<double>> samples;
}

class FaceTemplateStore {
  FaceTemplateStore(
    this.database, {
    required this.cipher,
    required this.authorizeEnrollment,
    required this.actor,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LocalDatabase database;
  final TemplateCipher cipher;
  final void Function() authorizeEnrollment;
  final String Function() actor;
  final DateTime Function() _clock;
  String? _cacheVersion;
  List<_ActiveFace>? _cachedFaces;

  String _context(String number, int consent, String id) =>
      '${FaceEngine.modelId}|$number|$consent|$id';

  Future<List<Map<String, Object?>>> _active(DatabaseExecutor db) =>
      db.rawQuery(
        '''
    SELECT t.*, e.name AS employee_name FROM face_templates t
    JOIN employees e ON e.number = t.employee_number
    JOIN consent_records c ON c.id = t.consent_id
    WHERE t.model_id = ? AND c.kind = 'recorded' AND c.id = (
      SELECT id FROM consent_records WHERE employee_number = t.employee_number ORDER BY id DESC LIMIT 1
    )
  ''',
        [FaceEngine.modelId],
      );

  Future<List<List<double>>> _decode(Map<String, Object?> row) async {
    final bytes = await cipher.unseal(
      Uint8List.fromList((row['encrypted_template'] as List).cast<int>()),
      _context(
        row['employee_number'] as String,
        row['consent_id'] as int,
        row['id'] as String,
      ),
    );
    final raw = jsonDecode(utf8.decode(bytes)) as List;
    return FaceMatching.samples(
      raw
          .map(
            (sample) =>
                (sample as List).map((v) => (v as num).toDouble()).toList(),
          )
          .toList(),
    );
  }

  Future<List<_ActiveFace>> _activeFaces() async {
    final db = await database.open();
    // A tiny query detects enrollment and consent revocation without
    // decrypting every template on every check-in.
    final marker = (await db.rawQuery('''
      SELECT COUNT(*) AS total, COALESCE(MAX(rowid), 0) AS newest
      FROM face_templates
    ''')).single;
    final version = '${marker['total']}:${marker['newest']}';
    if (_cacheVersion == version && _cachedFaces != null) {
      return _cachedFaces!;
    }
    final faces = <_ActiveFace>[];
    for (final row in await _active(db)) {
      faces.add(
        _ActiveFace(
          employeeNumber: row['employee_number'] as String,
          employeeName: row['employee_name'] as String,
          templateId: row['id'] as String,
          consentId: row['consent_id'] as int,
          samples: await _decode(row),
        ),
      );
    }
    _cachedFaces = List.unmodifiable(faces);
    _cacheVersion = version;
    return _cachedFaces!;
  }

  Future<void> enroll(String employeeNumber, List<List<double>> values) async {
    authorizeEnrollment();
    final samples = FaceMatching.samples(values);
    final db = await database.open();
    await db.transaction((txn) async {
      authorizeEnrollment();
      final consents = await txn.query(
        'consent_records',
        where: 'employee_number = ?',
        whereArgs: [employeeNumber],
        orderBy: 'id DESC',
        limit: 1,
      );
      if (consents.isEmpty || consents.single['kind'] != 'recorded') {
        throw const FaceRuleError(
          'Registra el consentimiento firmado antes de guardar el rostro.',
        );
      }
      final consentId = consents.single['id'] as int;
      for (final row in await _active(txn)) {
        if (row['employee_number'] == employeeNumber) continue;
        if (FaceMatching.score(samples, await _decode(row)) >=
            FaceMatching.threshold) {
          throw const FaceRuleError(
            'Este rostro se parece a uno ya registrado. Revisa el empleado antes de continuar.',
          );
        }
      }
      final id = List.generate(
        24,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final bytes = await cipher.seal(
        Uint8List.fromList(utf8.encode(jsonEncode(samples))),
        _context(employeeNumber, consentId, id),
      );
      authorizeEnrollment();
      await txn.delete(
        'face_templates',
        where: 'employee_number = ?',
        whereArgs: [employeeNumber],
      );
      await txn.insert('face_templates', {
        'id': id,
        'employee_number': employeeNumber,
        'consent_id': consentId,
        'model_id': FaceEngine.modelId,
        'encrypted_template': bytes,
        'created_at': _clock().toUtc().millisecondsSinceEpoch,
      });
      await writeAudit(
        txn,
        action: AuditAction.faceEnrolled,
        actor: actor(),
        details: {
          'employeeNumber': employeeNumber,
          'model': FaceEngine.modelId,
        },
        time: _clock(),
      );
    });
    _cachedFaces = null;
    _cacheVersion = null;
  }

  Future<FaceMatch> identify(List<List<double>> values) async {
    final samples = FaceMatching.samples(values);
    final faces = await _activeFaces();
    if (faces.isEmpty) {
      throw const FaceRuleError(
        'Todavía no hay rostros registrados. Solicita apoyo a RH.',
      );
    }
    _ActiveFace? best;
    var first = -1.0;
    var second = -1.0;
    for (final face in faces) {
      final score = FaceMatching.score(samples, face.samples);
      if (score > first) {
        second = first;
        first = score;
        best = face;
      } else if (score > second) {
        second = score;
      }
    }
    if (best == null ||
        first < FaceMatching.threshold ||
        first - second < FaceMatching.margin) {
      throw const FaceRuleError(
        'No pude identificarte con suficiente confianza. Repite la toma o solicita apoyo a RH.',
      );
    }
    return FaceMatch._(
      best.employeeNumber,
      best.employeeName,
      best.templateId,
      best.consentId,
      first,
      _clock().toUtc(),
    );
  }
}
