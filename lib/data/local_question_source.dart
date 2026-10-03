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

  /// Picks a random id and returns the first matching clue at or after it,
  /// wrapping around to the start. Clue ids run from 1 with no gaps, so with
  /// no filter every clue is equally likely; with a filter, clues that follow
  /// a long run of non-matching ones are a little more likely.
  @override
  Future<JeopardyQuestion> randomQuestion({QuestionFilter filter = QuestionFilter.any}) async {
    final db = _db;
    if (db == null) throw StateError('LocalQuestionSource is not open');
    if (_maxId == 0) throw const NoQuestionFound('The clue database is empty.');

    final where = <String>['c.id >= ?'];
    final args = <Object>[];
    final rounds = filter.rounds;
    if (rounds != null) {
      if (rounds.isEmpty) throw const NoQuestionFound();
      where.add('c.round IN (${List.filled(rounds.length, '?').join(', ')})');
      args.addAll(rounds);
    }
    if (filter.from != null) {
      where.add('g.air_date >= ?');
      args.add(_isoDate(filter.from!));
    }
    if (filter.to != null) {
      where.add('g.air_date <= ?');
      args.add(_isoDate(filter.to!));
    }
    final sql = '$_select WHERE ${where.join(' AND ')} ORDER BY c.id LIMIT 1';

    final start = 1 + _random.nextInt(_maxId);
    var rows = await db.rawQuery(sql, [start, ...args]);
    if (rows.isEmpty && start > 1) rows = await db.rawQuery(sql, [1, ...args]);
    if (rows.isEmpty) throw const NoQuestionFound();
    return _fromRow(rows.first);
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

  static String _isoDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
