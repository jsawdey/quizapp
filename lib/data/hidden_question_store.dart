import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:quizapp/model/question.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

/// Questions the user has hidden, keyed by (sourceId, key) so the list works
/// for every source and survives rebuilding the clue database.
abstract class HiddenQuestionStore {
  Future<void> open();
  bool isHidden(Question question);
  Future<void> hide(Question question);
  Future<void> close();
}

/// Keeps hidden questions in memory only. Used by tests.
class InMemoryHiddenQuestionStore implements HiddenQuestionStore {
  final Set<String> _hidden = {};

  @override
  Future<void> open() async {}

  @override
  bool isHidden(Question question) => _hidden.contains(_id(question));

  @override
  Future<void> hide(Question question) async => _hidden.add(_id(question));

  @override
  Future<void> close() async {}
}

/// Stores hidden questions in `user.db`, kept apart from the clue database so
/// replacing that never loses them. All rows are loaded into memory on open.
class SqfliteHiddenQuestionStore implements HiddenQuestionStore {
  // Resolved on open: sqflite's global factory isn't available off-device.
  final sqflite.DatabaseFactory? _databaseFactory;
  final Future<String> Function() _path;
  sqflite.Database? _db;
  final Set<String> _hidden = {};

  SqfliteHiddenQuestionStore({sqflite.DatabaseFactory? databaseFactory,
    Future<String> Function()? path})
      : _databaseFactory = databaseFactory,
        _path = path ?? _defaultPath;

  static Future<String> _defaultPath() async =>
      p.join((await getApplicationSupportDirectory()).path, 'user.db');

  @override
  Future<void> open() async {
    if (_db != null) return;
    final db = await (_databaseFactory ?? sqflite.databaseFactory).openDatabase(await _path(),
        options: sqflite.OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) => db.execute('''
            CREATE TABLE hidden (
              source_id    TEXT NOT NULL,
              question_key TEXT NOT NULL,
              hidden_at    TEXT NOT NULL,
              PRIMARY KEY (source_id, question_key)
            )'''),
        ));
    final rows = await db.query('hidden', columns: ['source_id', 'question_key']);
    _hidden
      ..clear()
      ..addAll(rows.map((r) => _key(r['source_id'] as String, r['question_key'] as String)));
    _db = db;
  }

  @override
  bool isHidden(Question question) => _hidden.contains(_id(question));

  @override
  Future<void> hide(Question question) async {
    final db = _db;
    if (db == null) throw StateError('HiddenQuestionStore is not open');
    await db.insert('hidden', {
      'source_id': question.sourceId,
      'question_key': question.key,
      'hidden_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.ignore);
    _hidden.add(_id(question));
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}

/// Stores hidden questions with shared_preferences, which is the browser's
/// localStorage on the web, where sqflite isn't available. Like the sqflite
/// store, it loads everything into memory on open.
class SharedPrefsHiddenQuestionStore implements HiddenQuestionStore {
  static const prefsKey = 'hidden_questions';

  final Future<SharedPreferences> Function() _prefs;
  SharedPreferences? _store;
  final Set<String> _hidden = {};

  SharedPrefsHiddenQuestionStore({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance;

  @override
  Future<void> open() async {
    if (_store != null) return;
    final store = await _prefs();
    _hidden
      ..clear()
      ..addAll(store.getStringList(prefsKey) ?? const []);
    _store = store;
  }

  @override
  bool isHidden(Question question) => _hidden.contains(_id(question));

  @override
  Future<void> hide(Question question) async {
    final store = _store;
    if (store == null) throw StateError('HiddenQuestionStore is not open');
    final id = _id(question);
    if (_hidden.contains(id)) return;
    await store.setStringList(prefsKey, [..._hidden, id]);
    _hidden.add(id);
  }

  @override
  Future<void> close() async => _store = null;
}

String _id(Question q) => _key(q.sourceId, q.key);

// A separator that can't appear in a source id.
String _key(String sourceId, String key) => '$sourceId\u0000$key';
