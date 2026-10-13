import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:quizapp/model/history.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

/// Answers and games waiting to be sent to the server, oldest first.
class HistoryBatch {
  final List<HistoryAnswer> answers;
  final List<HistoryGame> games;
  const HistoryBatch({this.answers = const [], this.games = const []});

  bool get isEmpty => answers.isEmpty && games.isEmpty;
  int get length => answers.length + games.length;
}

/// How far a store has synced with its server: which history the server
/// holds, how far into it the store has fetched, and when it last synced.
class HistorySyncState {
  final String? historyId;
  final int cursor;
  final DateTime? lastSynced;
  const HistorySyncState({this.historyId, this.cursor = 0, this.lastSynced});

  static const initial = HistorySyncState();
}

/// Where the device keeps the score history (docs/history-plan.md §3).
abstract class HistoryStore {
  /// Whether it keeps the whole history, or only what is waiting to be sent:
  /// a web build's server holds the history for it.
  bool get keepsHistory;

  Future<void> open();

  /// Keeps [answer], waiting to be sent. Replaces one with the same id.
  Future<void> putAnswer(HistoryAnswer answer);

  /// Keeps [game], waiting to be sent, unless the store has a newer row for
  /// that game.
  Future<void> putGame(HistoryGame game);

  /// Everything it holds; empty unless [keepsHistory].
  Future<HistorySnapshot> all();

  /// The oldest of what's waiting to be sent.
  Future<HistoryBatch> unsent({int answers = 500, int games = 100});

  /// [batch] reached the server. Anything changed since it was taken from
  /// [unsent] is still waiting.
  Future<void> markSent(HistoryBatch batch);

  /// How many answers are waiting to be sent.
  Future<int> unsentCount();

  /// Adds what the server sent, as already sent. Its own rows still waiting
  /// to be sent win, and so does a newer row for a game.
  Future<void> merge(List<HistoryAnswer> answers, List<HistoryGame> games);

  /// Everything it holds is waiting to be sent again: the server's history
  /// was replaced.
  Future<void> resendAll();

  Future<HistorySyncState> syncState();
  Future<void> saveSyncState(HistorySyncState state);

  Future<void> close();
}

/// Keeps the history in memory. Used by tests, and as the web store's
/// working copy.
class InMemoryHistoryStore implements HistoryStore {
  @override
  final bool keepsHistory;

  /// The most answers it keeps waiting to be sent; the oldest go first.
  final int? maxUnsent;

  // Map and set literals keep insertion order, so the oldest come first.
  final _answers = <String, HistoryAnswer>{};
  final _unsentAnswers = <String>{};
  final _games = <String, HistoryGame>{};
  final _unsentGames = <String>{};
  HistorySyncState _state = HistorySyncState.initial;

  InMemoryHistoryStore({this.keepsHistory = true, this.maxUnsent});

  /// Called after every change; the web store saves there.
  @protected
  Future<void> changed() async {}

  @override
  Future<void> open() async {}

  @override
  Future<void> putAnswer(HistoryAnswer answer) async {
    _answers.remove(answer.id);
    _answers[answer.id] = answer;
    _unsentAnswers
      ..remove(answer.id)
      ..add(answer.id);
    final maxUnsent = this.maxUnsent;
    while (maxUnsent != null && _unsentAnswers.length > maxUnsent) {
      final oldest = _unsentAnswers.first;
      debugPrint('History: dropping answer $oldest; more than $maxUnsent are waiting');
      _unsentAnswers.remove(oldest);
      if (!keepsHistory) _answers.remove(oldest);
    }
    await changed();
  }

  @override
  Future<void> putGame(HistoryGame game) async {
    final old = _games[game.id];
    if (old != null && old.updatedAt.isAfter(game.updatedAt)) return;
    _games.remove(game.id);
    _games[game.id] = game;
    _unsentGames
      ..remove(game.id)
      ..add(game.id);
    await changed();
  }

  @override
  Future<HistorySnapshot> all() async => keepsHistory
      ? HistorySnapshot(answers: _answers.values.toList(), games: _games.values.toList())
      : HistorySnapshot.empty;

  @override
  Future<HistoryBatch> unsent({int answers = 500, int games = 100}) async => HistoryBatch(
        answers: _unsentAnswers.take(answers).map((id) => _answers[id]!).toList(),
        games: _unsentGames.take(games).map((id) => _games[id]!).toList(),
      );

  @override
  Future<void> markSent(HistoryBatch batch) async {
    for (final answer in batch.answers) {
      if (_answers[answer.id] != answer) continue;
      _unsentAnswers.remove(answer.id);
      if (!keepsHistory) _answers.remove(answer.id);
    }
    for (final game in batch.games) {
      if (_games[game.id] != game) continue;
      _unsentGames.remove(game.id);
      if (!keepsHistory) _games.remove(game.id);
    }
    await changed();
  }

  @override
  Future<int> unsentCount() async => _unsentAnswers.length;

  @override
  Future<void> merge(List<HistoryAnswer> answers, List<HistoryGame> games) async {
    if (!keepsHistory) return;
    for (final answer in answers) {
      if (!_unsentAnswers.contains(answer.id)) _answers[answer.id] = answer;
    }
    for (final game in games) {
      final old = _games[game.id];
      if (_unsentGames.contains(game.id) ||
          (old != null && old.updatedAt.isAfter(game.updatedAt))) {
        continue;
      }
      _games[game.id] = game;
    }
    await changed();
  }

  @override
  Future<void> resendAll() async {
    _unsentAnswers.addAll(_answers.keys);
    _unsentGames.addAll(_games.keys);
    await changed();
  }

  @override
  Future<HistorySyncState> syncState() async => _state;

  @override
  Future<void> saveSyncState(HistorySyncState state) async {
    _state = state;
    await changed();
  }

  @override
  Future<void> close() async {}
}

/// The web build's store: only what's waiting to be sent, as JSON in
/// shared_preferences (the browser's localStorage), at most 10,000 answers.
/// The server that served the page holds the history itself.
class SharedPrefsHistoryStore extends InMemoryHistoryStore {
  static const prefsKey = 'history_queue';

  final Future<SharedPreferences> Function() _prefs;

  SharedPrefsHistoryStore({Future<SharedPreferences> Function()? prefs, super.maxUnsent = 10000})
      : _prefs = prefs ?? SharedPreferences.getInstance,
        super(keepsHistory: false);

  /// Reads the saved queue. One that can't be read is logged and starts
  /// empty, as the saved score does.
  @override
  Future<void> open() async {
    final saved = (await _prefs()).getString(prefsKey);
    if (saved == null) return;
    try {
      final decoded = json.decode(saved) as Map<String, dynamic>;
      for (final item in decoded['answers'] as List) {
        final answer = HistoryAnswer.fromJson(item);
        if (answer != null) {
          _answers[answer.id] = answer;
          _unsentAnswers.add(answer.id);
        }
      }
      for (final item in decoded['games'] as List) {
        final game = HistoryGame.fromJson(item);
        if (game != null) {
          _games[game.id] = game;
          _unsentGames.add(game.id);
        }
      }
      _state = HistorySyncState(historyId: decoded['history_id'] as String?,
          lastSynced: decoded['last_synced'] is String
              ? DateTime.tryParse(decoded['last_synced'] as String) : null);
    } catch (error) {
      debugPrint('Could not read the history waiting to be sent: $error');
    }
  }

  @override
  Future<void> changed() async {
    final lastSynced = _state.lastSynced;
    await (await _prefs()).setString(prefsKey, json.encode({
      'answers': [for (final id in _unsentAnswers) _answers[id]!.toJson()],
      'games': [for (final id in _unsentGames) _games[id]!.toJson()],
      'history_id': _state.historyId,
      'last_synced': lastSynced?.toIso8601String(),
    }));
  }
}

/// Phones' and desktop builds' store: the whole history in `history.db`,
/// beside `user.db`. Kept apart from it so the two stores never have to
/// agree on a schema version.
class SqfliteHistoryStore implements HistoryStore {
  // Resolved on open: sqflite's global factory isn't available off-device.
  final sqflite.DatabaseFactory? _databaseFactory;
  final Future<String> Function() _path;
  sqflite.Database? _db;

  SqfliteHistoryStore({sqflite.DatabaseFactory? databaseFactory,
    Future<String> Function()? path})
      : _databaseFactory = databaseFactory,
        _path = path ?? _defaultPath;

  static Future<String> _defaultPath() async =>
      p.join((await getApplicationSupportDirectory()).path, 'history.db');

  @override
  bool get keepsHistory => true;

  sqflite.Database get _open {
    final db = _db;
    if (db == null) throw StateError('The history store is not open');
    return db;
  }

  @override
  Future<void> open() async {
    if (_db != null) return;
    _db = await (_databaseFactory ?? sqflite.databaseFactory).openDatabase(await _path(),
        options: sqflite.OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            // As the server's tables (tool/serve_clues.py), plus whether
            // each row has been sent.
            await db.execute('''
              CREATE TABLE answers (
                id TEXT PRIMARY KEY, game TEXT NOT NULL,
                answered_at TEXT NOT NULL, utc_offset INTEGER NOT NULL,
                namespace TEXT NOT NULL, question_key TEXT NOT NULL,
                category TEXT NOT NULL, format TEXT NOT NULL, round INTEGER,
                board_row INTEGER, value INTEGER, daily_double INTEGER NOT NULL,
                difficulty TEXT, correct INTEGER NOT NULL, sent INTEGER NOT NULL)''');
            await db.execute('''
              CREATE TABLE games (
                id TEXT PRIMARY KEY, started TEXT, updated_at TEXT NOT NULL,
                answered INTEGER NOT NULL, correct INTEGER NOT NULL,
                best INTEGER NOT NULL, dollars INTEGER NOT NULL,
                valued INTEGER NOT NULL, sent INTEGER NOT NULL)''');
            await db.execute(
                'CREATE TABLE meta (name TEXT PRIMARY KEY, value TEXT NOT NULL)');
          },
        ));
  }

  @override
  Future<void> putAnswer(HistoryAnswer answer) =>
      _open.insert('answers', _answerRow(answer, sent: false),
          conflictAlgorithm: sqflite.ConflictAlgorithm.replace);

  @override
  Future<void> putGame(HistoryGame game) => _open.transaction((txn) async {
        final old = await _game(txn, game.id);
        if (old != null && old.updatedAt.isAfter(game.updatedAt)) return;
        await txn.insert('games', _gameRow(game, sent: false),
            conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
      });

  @override
  Future<HistorySnapshot> all() async => HistorySnapshot(
        answers: (await _open.query('answers')).map(_answerFrom).nonNulls.toList(),
        games: (await _open.query('games')).map(_gameFrom).nonNulls.toList(),
      );

  @override
  Future<HistoryBatch> unsent({int answers = 500, int games = 100}) async => HistoryBatch(
        // rowid order: a replaced row goes to the end, as the newest.
        answers: (await _open.query('answers', where: 'sent = 0', orderBy: 'rowid',
            limit: answers)).map(_answerFrom).nonNulls.toList(),
        games: (await _open.query('games', where: 'sent = 0', orderBy: 'rowid',
            limit: games)).map(_gameFrom).nonNulls.toList(),
      );

  @override
  Future<void> markSent(HistoryBatch batch) => _open.transaction((txn) async {
        for (final answer in batch.answers) {
          final rows = await txn.query('answers', where: 'id = ?', whereArgs: [answer.id]);
          if (rows.isNotEmpty && _answerFrom(rows.first) == answer) {
            await txn.update('answers', {'sent': 1}, where: 'id = ?', whereArgs: [answer.id]);
          }
        }
        for (final game in batch.games) {
          if (await _game(txn, game.id) == game) {
            await txn.update('games', {'sent': 1}, where: 'id = ?', whereArgs: [game.id]);
          }
        }
      });

  @override
  Future<int> unsentCount() async => sqflite.Sqflite.firstIntValue(
      await _open.rawQuery('SELECT COUNT(*) FROM answers WHERE sent = 0')) ?? 0;

  @override
  Future<void> merge(List<HistoryAnswer> answers, List<HistoryGame> games) =>
      _open.transaction((txn) async {
        for (final answer in answers) {
          final rows = await txn.query('answers', columns: ['sent'], where: 'id = ?',
              whereArgs: [answer.id]);
          if (rows.isNotEmpty && rows.first['sent'] == 0) continue;
          await txn.insert('answers', _answerRow(answer, sent: true),
              conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
        }
        for (final game in games) {
          final rows = await txn.query('games', where: 'id = ?', whereArgs: [game.id]);
          if (rows.isNotEmpty) {
            final old = _gameFrom(rows.first);
            if (rows.first['sent'] == 0 ||
                (old != null && old.updatedAt.isAfter(game.updatedAt))) {
              continue;
            }
          }
          await txn.insert('games', _gameRow(game, sent: true),
              conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
        }
      });

  @override
  Future<void> resendAll() async {
    await _open.update('answers', {'sent': 0});
    await _open.update('games', {'sent': 0});
  }

  @override
  Future<HistorySyncState> syncState() async {
    final meta = {
      for (final row in await _open.query('meta'))
        row['name'] as String: row['value'] as String,
    };
    final lastSynced = meta['last_synced'];
    return HistorySyncState(
      historyId: meta['history_id'],
      cursor: int.tryParse(meta['cursor'] ?? '') ?? 0,
      lastSynced: lastSynced == null ? null : DateTime.tryParse(lastSynced),
    );
  }

  @override
  Future<void> saveSyncState(HistorySyncState state) => _open.transaction((txn) async {
        await txn.delete('meta');
        final values = {
          'history_id': state.historyId,
          'cursor': '${state.cursor}',
          'last_synced': state.lastSynced?.toUtc().toIso8601String(),
        };
        for (final MapEntry(:key, :value) in values.entries) {
          if (value != null) await txn.insert('meta', {'name': key, 'value': value});
        }
      });

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  static Future<HistoryGame?> _game(sqflite.DatabaseExecutor db, String id) async {
    final rows = await db.query('games', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _gameFrom(rows.first);
  }

  // Rows use the server's column names: key, row and right are SQL keywords.
  static Map<String, Object?> _answerRow(HistoryAnswer answer, {required bool sent}) {
    final json = answer.toJson();
    return {
      ...json..removeWhere((name, _) => const {'key', 'row', 'right'}.contains(name)),
      'question_key': answer.key,
      'board_row': answer.row,
      'daily_double': answer.dailyDouble ? 1 : 0,
      'correct': answer.right ? 1 : 0,
      'sent': sent ? 1 : 0,
    };
  }

  static HistoryAnswer? _answerFrom(Map<String, Object?> row) => HistoryAnswer.fromJson({
        ...row,
        'key': row['question_key'],
        'row': row['board_row'],
        'daily_double': row['daily_double'] == 1,
        'right': row['correct'] == 1,
      });

  static Map<String, Object?> _gameRow(HistoryGame game, {required bool sent}) {
    final json = game.toJson();
    return {
      ...json..remove('right'),
      'correct': game.right,
      'sent': sent ? 1 : 0,
    };
  }

  static HistoryGame? _gameFrom(Map<String, Object?> row) =>
      HistoryGame.fromJson({...row, 'right': row['correct']});
}
