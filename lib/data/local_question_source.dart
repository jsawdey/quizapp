import 'dart:async';
import 'dart:convert' show json;
import 'dart:math';

import 'package:quizapp/data/clue_database.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

/// Reads questions from the bundled clue or trivia database (see
/// [ClueDatabase] and [LocalDataset]).
class LocalQuestionSource extends QuestionSource {
  /// Used when the database's meta table has no `dataset_namespace` (databases
  /// built before it was added).
  static const defaultNamespace = 'jwolle1';

  /// Which database this reads; fixed when the source is made, so the app
  /// knows which filters to offer before it opens.
  final LocalDataset dataset;

  static const _selectTrivia =
      'SELECT id, key, category, difficulty, question, answer, choices FROM questions';

  static const _select = '''
    SELECT c.id, c.clue_key, c.round, c.value, c.dd_wager, c.category_comment,
           c.clue, c.response, c.notes, cat.name AS category, g.air_date
    FROM clues c
    JOIN categories cat ON cat.id = c.category_id
    JOIN games g ON g.id = c.game_id''';

  /// The round's value for the top row of the board, as in
  /// [Question.boardRow]; the `?` is the day values doubled.
  static const _rowBase = '(CASE c.round WHEN 1 THEN 100 ELSE 200 END '
      '* CASE WHEN g.air_date >= ? THEN 2 ELSE 1 END)';

  final Future<sqflite.Database> Function() _openDatabase;
  final Random _random;
  sqflite.Database? _db;
  int _maxId = 0;
  String _namespace = defaultNamespace;
  String? _attribution;

  /// The clue ids each date range covers, or null for none. See [_idRange].
  final Map<(DateTime?, DateTime?), ({int first, int last})?> _idRanges = {};

  /// How many trivia questions each filter matches.
  final Map<QuestionFilter, int> _triviaCounts = {};

  /// Reads [database], or else the bundled [dataset].
  LocalQuestionSource({ClueDatabase? database, LocalDataset dataset = LocalDataset.clues,
    Random? random})
      : this.withDatabase((database ?? ClueDatabase(dataset: dataset)).open,
            dataset: database?.dataset ?? dataset, random: random);

  /// Uses an already-built database; for tests.
  LocalQuestionSource.withDatabase(this._openDatabase,
      {this.dataset = LocalDataset.clues, Random? random})
      : _random = random ?? Random();

  bool get _trivia => dataset == LocalDataset.trivia;

  @override
  String get description => 'the ${dataset.description}';

  @override
  Set<FilterKind> get supportedFilters => _trivia
      ? const {FilterKind.category, FilterKind.difficulty}
      : const {FilterKind.round, FilterKind.airDate, FilterKind.boardRow};

  /// The credit the database's license asks for, from its meta table.
  @override
  String? get attribution => _attribution;

  @override
  Future<void> open() async {
    if (_db != null) return;
    final db = await _openDatabase();
    final maxId = (await db.rawQuery(
        'SELECT MAX(id) AS max_id FROM ${_trivia ? 'questions' : 'clues'}'))
        .first['max_id'] as int?;
    final meta = {
      for (final row in await db.rawQuery(
          "SELECT key, value FROM meta WHERE key IN ('dataset_namespace', 'attribution')"))
        row['key'] as String: row['value'] as String,
    };
    _maxId = maxId ?? 0;
    _namespace = meta['dataset_namespace'] ?? defaultNamespace;
    _attribution = meta['attribution'];
    _db = db;
  }

  @override
  Future<List<String>> filterCategories() async {
    final db = _db;
    if (db == null) throw StateError('LocalQuestionSource is not open');
    if (!_trivia) return const [];
    final rows = await db.rawQuery('SELECT DISTINCT category FROM questions ORDER BY category');
    return [for (final row in rows) row['category'] as String];
  }

  /// Picks a random id within the filter's date range and returns the first
  /// matching clue at or after it, wrapping around to the start of the range.
  /// Clue ids run from 1 with no gaps, so with no round filter every clue in
  /// the range is equally likely; with one, clues that follow a long run of
  /// non-matching ones are a little more likely.
  @override
  Future<Question> randomQuestion({QuestionFilter filter = QuestionFilter.any}) async {
    final db = _db;
    if (db == null) throw StateError('LocalQuestionSource is not open');
    if (_maxId == 0) throw NoQuestionFound('The ${dataset.description} is empty.');
    if (_trivia) return _randomTrivia(db, filter);

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
    final boardRows = filter.boardRows;
    if (boardRows != null) {
      if (boardRows.isEmpty) {
        where.add('c.round = 3');
      } else {
        // Final Jeopardy has no row, and passes whenever its round does.
        final rows = List.filled(boardRows.length, '?').join(', ');
        where.add('(c.round = 3 OR '
            '(c.value % $_rowBase = 0 AND c.value / $_rowBase IN ($rows)))');
        final doubledOn = isoDate(Question.valuesDoubledOn);
        args.addAll([doubledOn, doubledOn, ...boardRows]);
      }
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

  /// Without a filter, the question at a random id; with one, the one at a
  /// random place among those matching, counted once per filter.
  Future<Question> _randomTrivia(sqflite.Database db, QuestionFilter filter) async {
    final where = <String>[];
    final args = <Object>[];
    final categories = filter.categories;
    if (categories != null) {
      where.add('category IN (${List.filled(categories.length, '?').join(', ')})');
      args.addAll(categories);
    }
    final difficulties = filter.difficulties;
    if (difficulties != null) {
      where.add('difficulty IN (${List.filled(difficulties.length, '?').join(', ')})');
      args.addAll(difficulties);
    }
    final List<Map<String, Object?>> rows;
    if (where.isEmpty) {
      rows = await db.rawQuery('$_selectTrivia WHERE id = ?', [1 + _random.nextInt(_maxId)]);
    } else {
      final condition = 'WHERE ${where.join(' AND ')}';
      final count = _triviaCounts[filter] ??= (await db.rawQuery(
          'SELECT COUNT(*) AS n FROM questions $condition', args)).first['n'] as int;
      if (count == 0) throw const NoQuestionFound();
      rows = await db.rawQuery('$_selectTrivia $condition ORDER BY id LIMIT 1 OFFSET ?',
          [...args, _random.nextInt(count)]);
    }
    if (rows.isEmpty) throw const NoQuestionFound();
    return _fromTriviaRow(rows.first);
  }

  Question _fromTriviaRow(Map<String, Object?> row) {
    final answer = row['answer'] as String;
    final decoded = json.decode(row['choices'] as String? ?? 'null');
    final choices = decoded is List ? decoded.whereType<String>().toList() : null;
    return Question(
      sourceId: _namespace,
      key: row['key'] as String,
      question: row['question'] as String,
      answer: answer,
      category: row['category'] as String,
      // A database the builder didn't write could break this; then the
      // question still plays, as a flip card.
      choices: choices != null && Question.validChoices(choices, answer) ? choices : null,
      difficulty: row['difficulty'] as String?,
      raw: Map.of(row),
    );
  }

  Question _fromRow(Map<String, Object?> row) {
    final round = row['round'] as int;
    final value = row['value'] as int;
    final wager = row['dd_wager'] as int;
    return Question(
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
    _triviaCounts.clear();
  }
}
