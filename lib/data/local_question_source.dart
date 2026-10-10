import 'dart:async';
import 'dart:math';

import 'package:quizapp/data/clue_database.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

/// Reads questions from the bundled clue database (see [ClueDatabase]).
class LocalQuestionSource extends QuestionSource {
  /// Used when the database's meta table has no `dataset_namespace` (databases
  /// built before it was added).
  static const defaultNamespace = 'jwolle1';

  static const _select = '''
    SELECT c.id, c.clue_key, c.round, c.value, c.dd_wager, c.category_comment,
           c.clue, c.response, c.notes, cat.name AS category, g.air_date
    FROM clues c
    JOIN categories cat ON cat.id = c.category_id
    JOIN games g ON g.id = c.game_id''';

  final Future<sqflite.Database> Function() _openDatabase;
  final Random _random;
  sqflite.Database? _db;
  int _maxId = 0;
  String _namespace = defaultNamespace;

  /// The clue ids each date range covers, or null for none. See [_idRange].
  final Map<(DateTime?, DateTime?), ({int first, int last})?> _idRanges = {};

  LocalQuestionSource({ClueDatabase? database, Random? random})
      : this.withDatabase((database ?? ClueDatabase()).open, random: random);

  /// Uses an already-built database; for tests.
  LocalQuestionSource.withDatabase(this._openDatabase, {Random? random})
      : _random = random ?? Random();

  @override
  String get description => 'the clue database';

  @override
  Future<void> open() async {
    if (_db != null) return;
    final db = await _openDatabase();
    final maxId = (await db.rawQuery('SELECT MAX(id) AS max_id FROM clues'))
        .first['max_id'] as int?;
    final namespace = await db.rawQuery(
        "SELECT value FROM meta WHERE key = 'dataset_namespace'");
    _maxId = maxId ?? 0;
    _namespace = namespace.isEmpty ? defaultNamespace : namespace.first['value'] as String;
    _db = db;
  }

  /// Picks a random id within the filter's date range and returns the first
  /// matching clue at or after it, wrapping around to the start of the range.
  /// Clue ids run from 1 with no gaps, so with no round filter every clue in
  /// the range is equally likely; with one, clues that follow a long run of
  /// non-matching ones are a little more likely.
  @override
  Future<JeopardyQuestion> randomQuestion({QuestionFilter filter = QuestionFilter.any}) async {
    final db = _db;
    if (db == null) throw StateError('LocalQuestionSource is not open');
    if (_maxId == 0) throw const NoQuestionFound('The clue database is empty.');

    final rounds = filter.rounds;
    if (rounds != null && rounds.isEmpty) throw const NoQuestionFound();
    final range = await _idRange(db, filter.from, filter.to);
    if (range == null) throw const NoQuestionFound();

    final where = <String>['c.id >= ?', 'c.id <= ?'];
    final args = <Object>[range.last];
    if (rounds != null) {
      // The unary plus keeps SQLite off the round index, which would sort
      // every matching clue; walking forward by id finds one in a few rows.
      where.add('+c.round IN (${List.filled(rounds.length, '?').join(', ')})');
      args.addAll(rounds);
    }
    if (filter.from != null) {
      where.add('g.air_date >= ?');
      args.add(isoDate(filter.from!));
    }
    if (filter.to != null) {
      where.add('g.air_date <= ?');
      args.add(isoDate(filter.to!));
    }
    final sql = '$_select WHERE ${where.join(' AND ')} ORDER BY c.id LIMIT 1';

    final start = range.first + _random.nextInt(range.last - range.first + 1);
    var rows = await db.rawQuery(sql, [start, ...args]);
    if (rows.isEmpty && start > range.first) {
      rows = await db.rawQuery(sql, [range.first, ...args]);
    }
    if (rows.isEmpty) throw const NoQuestionFound();
    return _fromRow(rows.first);
  }

  /// The first and last clue ids aired from [from] to [to], or null if no
  /// clue did. tool/build_clue_db.py numbers clues in air-date order, so a
  /// date range is a range of ids, found by binary search and cached. The
  /// query still checks the dates, so the order only affects fairness.
  Future<({int first, int last})?> _idRange(
      sqflite.Database db, DateTime? from, DateTime? to) async {
    if (from == null && to == null) return (first: 1, last: _maxId);
    final key = (from, to);
    if (_idRanges.containsKey(key)) return _idRanges[key];
    final first = from == null ? 1
        : await _firstId(db, (airDate) => airDate.compareTo(isoDate(from)) >= 0);
    final last = to == null ? _maxId
        : await _firstId(db, (airDate) => airDate.compareTo(isoDate(to)) > 0) - 1;
    return _idRanges[key] = first > last ? null : (first: first, last: last);
  }

  /// The lowest clue id whose air date passes [test], or `_maxId + 1` if none
  /// does. [test] must be false for early dates and true from some date on.
  Future<int> _firstId(sqflite.Database db, bool Function(String airDate) test) async {
    var low = 1, high = _maxId + 1;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      final rows = await db.rawQuery('SELECT g.air_date FROM clues c '
          'JOIN games g ON g.id = c.game_id WHERE c.id = ?', [mid]);
      if (test(rows.first['air_date'] as String)) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    return low;
  }

  JeopardyQuestion _fromRow(Map<String, Object?> row) {
    final round = row['round'] as int;
    final value = row['value'] as int;
    final wager = row['dd_wager'] as int;
    return JeopardyQuestion(
      sourceId: _namespace,
      key: '${row['clue_key']}',
      question: row['clue'] as String,
      answer: row['response'] as String,
      category: row['category'] as String,
      // Final Jeopardy clues are stored with value 0.
      value: round == 3 ? null : value,
      round: round,
      airDate: DateTime.parse(row['air_date'] as String),
      dailyDoubleWager: wager == 0 ? null : wager,
      categoryComment: row['category_comment'] as String?,
      notes: row['notes'] as String?,
      raw: Map.of(row),
    );
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
    _idRanges.clear();
  }
}
