import 'dart:math';

import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';
import 'package:quizapp/model/score.dart';

/// An id for an answer or a game in the history: 32 lowercase hex digits,
/// random enough that devices never pick the same one.
String newHistoryId([Random? random]) {
  final source = random ?? Random.secure();
  return List.generate(16, (_) => source.nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();
}

const _formatNames = {
  QuestionFormat.open: 'open',
  QuestionFormat.multipleChoice: 'multiple_choice',
  QuestionFormat.trueFalse: 'true_false',
};

/// One scored question, as the history keeps it and the server stores it
/// (docs/history-plan.md §2).
class HistoryAnswer {
  /// Made when the question gets its first result; a change of mind keeps it.
  final String id;

  /// The [HistoryGame.id] of the game it counted in.
  final String game;

  /// When it was answered, in UTC.
  final DateTime answeredAt;

  /// The device's offset from UTC at the time, in minutes, so the answer's
  /// day is the player's day wherever the history is read.
  final int utcOffset;

  final String namespace;
  final String key;
  final String category;
  final QuestionFormat format;

  /// For Jeopardy! clues; null for trivia.
  final int? round;
  final int? row;
  final int? value;
  final bool dailyDouble;

  /// For trivia; null for clues.
  final String? difficulty;

  final bool right;

  HistoryAnswer({required this.id, required this.game, required DateTime answeredAt,
    required this.utcOffset, required this.namespace, required this.key,
    required this.category, required this.format, this.round, this.row, this.value,
    this.dailyDouble = false, this.difficulty, required this.right})
      : answeredAt = answeredAt.toUtc();

  /// [question] answered [right] at [at], a local time.
  factory HistoryAnswer.of(Question question, {required String id, required String game,
      required bool right, required DateTime at}) {
    final round = question.round;
    final value = question.value;
    final difficulty = question.difficulty;
    return HistoryAnswer(
      id: id,
      game: game,
      answeredAt: at,
      utcOffset: at.timeZoneOffset.inMinutes,
      // Within the lengths the server accepts.
      namespace: _clip(question.sourceId, 100),
      key: _clip(question.key.isEmpty ? '?' : question.key, 200),
      category: _clip(question.category, 300),
      format: question.format,
      round: round != null && round >= 1 && round <= 3 ? round : null,
      row: question.boardRow,
      value: value != null && value >= 0 && value <= 1000000 ? value : null,
      dailyDouble: question.dailyDoubleWager != null,
      difficulty: difficulty == null || difficulty.isEmpty ? null : _clip(difficulty, 20),
      right: right,
    );
  }

  static String _clip(String text, int length) =>
      text.length <= length ? text : text.substring(0, length);

  /// The answer's day where it was played.
  DateTime get localDay {
    final local = answeredAt.add(Duration(minutes: utcOffset));
    return DateTime.utc(local.year, local.month, local.day);
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'game': game,
        'answered_at': answeredAt.toIso8601String(),
        'utc_offset': utcOffset,
        'namespace': namespace,
        'key': key,
        'category': category,
        'format': _formatNames[format],
        'round': round,
        'row': row,
        'value': value,
        'daily_double': dailyDouble,
        'difficulty': difficulty,
        'right': right,
      };

  /// Reads what [toJson] or the server wrote; null if [json] isn't one.
  static HistoryAnswer? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final format = _formatNames.entries
        .where((e) => e.value == json['format']).map((e) => e.key).firstOrNull;
    final answeredAt = json['answered_at'] is String
        ? DateTime.tryParse(json['answered_at'] as String) : null;
    final values = [json['id'], json['game'], json['namespace'], json['key'],
      json['category']];
    if (format == null || answeredAt == null || values.any((v) => v is! String) ||
        json['utc_offset'] is! int || json['right'] is! bool ||
        json['daily_double'] is! bool || !_optional<int>(json['round']) ||
        !_optional<int>(json['row']) || !_optional<int>(json['value']) ||
        !_optional<String>(json['difficulty'])) {
      return null;
    }
    return HistoryAnswer(
      id: json['id'] as String,
      game: json['game'] as String,
      answeredAt: answeredAt,
      utcOffset: json['utc_offset'] as int,
      namespace: json['namespace'] as String,
      key: json['key'] as String,
      category: json['category'] as String,
      format: format,
      round: json['round'] as int?,
      row: json['row'] as int?,
      value: json['value'] as int?,
      dailyDouble: json['daily_double'] as bool,
      difficulty: json['difficulty'] as String?,
      right: json['right'] as bool,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HistoryAnswer && other.id == id && other.game == game &&
      other.answeredAt == answeredAt && other.utcOffset == utcOffset &&
      other.namespace == namespace && other.key == key && other.category == category &&
      other.format == format && other.round == round && other.row == row &&
      other.value == value && other.dailyDouble == dailyDouble &&
      other.difficulty == difficulty && other.right == right;

  @override
  int get hashCode => Object.hash(id, game, answeredAt, utcOffset, namespace, key, category,
      format, round, row, value, dailyDouble, difficulty, right);

  @override
  String toString() => 'HistoryAnswer($id, $namespace:$key, ${right ? 'right' : 'wrong'})';
}

/// A game's totals, as the device's [Score] has them. Replaced by a newer
/// row for the same game as the game goes on.
class HistoryGame {
  final String id;

  /// The day the game's first question was scored.
  final DateTime? started;

  /// When these totals were taken, in UTC; the newest row for a game wins.
  final DateTime updatedAt;

  final int answered;
  final int right;
  final int best;
  final int dollars;
  final int valued;

  HistoryGame({required this.id, this.started, required DateTime updatedAt,
    required this.answered, required this.right, required this.best,
    required this.dollars, required this.valued})
      : updatedAt = updatedAt.toUtc();

  factory HistoryGame.of(String id, Score score, {required DateTime now}) => HistoryGame(
        id: id, started: score.started, updatedAt: now, answered: score.answered,
        right: score.right, best: score.best, dollars: score.dollars, valued: score.valued);

  Map<String, Object?> toJson() {
    final started = this.started;
    return {
      'id': id,
      'started': started == null ? null : isoDate(started),
      'updated_at': updatedAt.toIso8601String(),
      'answered': answered,
      'right': right,
      'best': best,
      'dollars': dollars,
      'valued': valued,
    };
  }

  /// Reads what [toJson] or the server wrote; null if [json] isn't one.
  static HistoryGame? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final updatedAt = json['updated_at'] is String
        ? DateTime.tryParse(json['updated_at'] as String) : null;
    final started = json['started'];
    final startedOn = started is String ? DateTime.tryParse(started) : null;
    final counts = [json['answered'], json['right'], json['best'], json['dollars'],
      json['valued']];
    if (json['id'] is! String || updatedAt == null || counts.any((c) => c is! int) ||
        (started != null && startedOn == null)) {
      return null;
    }
    return HistoryGame(
      id: json['id'] as String,
      started: startedOn == null ? null : DateTime(startedOn.year, startedOn.month, startedOn.day),
      updatedAt: updatedAt,
      answered: json['answered'] as int,
      right: json['right'] as int,
      best: json['best'] as int,
      dollars: json['dollars'] as int,
      valued: json['valued'] as int,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HistoryGame && other.id == id && other.started == started &&
      other.updatedAt == updatedAt && other.answered == answered && other.right == right &&
      other.best == best && other.dollars == dollars && other.valued == valued;

  @override
  int get hashCode =>
      Object.hash(id, started, updatedAt, answered, right, best, dollars, valued);

  @override
  String toString() => 'HistoryGame($id, $right/$answered, best $best, \$$dollars)';
}

/// Every answer and game a history holds.
class HistorySnapshot {
  final List<HistoryAnswer> answers;
  final List<HistoryGame> games;
  const HistorySnapshot({this.answers = const [], this.games = const []});

  static const empty = HistorySnapshot();
}

bool _optional<T>(Object? value) => value == null || value is T;
