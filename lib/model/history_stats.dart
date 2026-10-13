import 'package:quizapp/model/history.dart';

/// Right out of answered.
class Tally {
  final int answered;
  final int right;
  const Tally([this.answered = 0, this.right = 0]);

  static const zero = Tally();

  /// From 0 to 1; 0 when nothing was answered.
  double get fraction => answered == 0 ? 0 : right / answered;

  Tally add(bool right) => Tally(answered + 1, this.right + (right ? 1 : 0));

  @override
  bool operator ==(Object other) =>
      other is Tally && other.answered == answered && other.right == right;

  @override
  int get hashCode => Object.hash(answered, right);

  @override
  String toString() => '$right/$answered';
}

/// A category's tally. Categories are told apart by source as well as name.
class CategoryTally {
  final String namespace;
  final String category;
  final Tally tally;
  const CategoryTally(this.namespace, this.category, this.tally);

  @override
  bool operator ==(Object other) =>
      other is CategoryTally && other.namespace == namespace &&
      other.category == category && other.tally == tally;

  @override
  int get hashCode => Object.hash(namespace, category, tally);

  @override
  String toString() => '$category ($namespace): $tally';
}

/// The History screen's figures, worked out from the answers and games a
/// history holds (docs/history-plan.md §3). The only place they are
/// computed, so every platform shows the same.
class HistoryStats {
  /// How many answers a category needs to count as strongest or weakest.
  static const categoryMinimum = 10;
  static const categoryCount = 5;
  static const recentGameCount = 10;

  final Tally total;
  final Tally last30Days;
  final Tally last7Days;

  /// Jeopardy! clues by round (1 to 3) and board row (1 to 5), only those
  /// with answers, in order.
  final Map<int, Tally> byRound;
  final Map<int, Tally> byRow;

  /// Trivia by difficulty: easy, medium and hard first, then any others.
  final Map<String, Tally> byDifficulty;

  final List<CategoryTally> strongest;
  final List<CategoryTally> weakest;

  /// The best streak of any game.
  final int bestStreak;

  /// The latest games, newest first.
  final List<HistoryGame> recentGames;

  const HistoryStats._({required this.total, required this.last30Days,
    required this.last7Days, required this.byRound, required this.byRow,
    required this.byDifficulty, required this.strongest, required this.weakest,
    required this.bestStreak, required this.recentGames});

  bool get isEmpty => total.answered == 0 && recentGames.isEmpty;

  /// The figures for [answers] and [games], with the last 7 and 30 days
  /// ending on the day of [now], a local time. Each answer's day is its own
  /// local day (see [HistoryAnswer.localDay]).
  factory HistoryStats.compute(List<HistoryAnswer> answers, List<HistoryGame> games,
      {required DateTime now}) {
    final today = DateTime.utc(now.year, now.month, now.day);
    final from30 = today.subtract(const Duration(days: 29));
    final from7 = today.subtract(const Duration(days: 6));
    var total = Tally.zero, last30 = Tally.zero, last7 = Tally.zero;
    final rounds = <int, Tally>{};
    final rows = <int, Tally>{};
    final difficulties = <String, Tally>{};
    final categories = <(String, String), Tally>{};

    for (final answer in answers) {
      final right = answer.right;
      total = total.add(right);
      final day = answer.localDay;
      if (!day.isBefore(from30) && !day.isAfter(today)) last30 = last30.add(right);
      if (!day.isBefore(from7) && !day.isAfter(today)) last7 = last7.add(right);
      final round = answer.round;
      if (round != null) rounds[round] = (rounds[round] ?? Tally.zero).add(right);
      final row = answer.row;
      if (row != null) rows[row] = (rows[row] ?? Tally.zero).add(right);
      final difficulty = answer.difficulty;
      if (difficulty != null) {
        difficulties[difficulty] = (difficulties[difficulty] ?? Tally.zero).add(right);
      }
      final category = (answer.namespace, answer.category);
      categories[category] = (categories[category] ?? Tally.zero).add(right);
    }

    final ranked = [
      for (final MapEntry(key: (namespace, category), value: tally) in categories.entries)
        if (tally.answered >= categoryMinimum) CategoryTally(namespace, category, tally),
    ];
    // At the same percentage, more answers make it surer: 18/20 before 9/10.
    int byMoreAnswers(CategoryTally a, CategoryTally b) =>
        b.tally.answered.compareTo(a.tally.answered);
    final strongest = ([...ranked]..sort((a, b) {
          final order = b.tally.fraction.compareTo(a.tally.fraction);
          return order != 0 ? order : byMoreAnswers(a, b);
        })).take(categoryCount).toList();
    final weakest = (ranked.where((c) => !strongest.contains(c)).toList()..sort((a, b) {
          final order = a.tally.fraction.compareTo(b.tally.fraction);
          return order != 0 ? order : byMoreAnswers(a, b);
        })).take(categoryCount).toList();

    const knownDifficulties = ['easy', 'medium', 'hard'];
    final otherDifficulties = difficulties.keys
        .where((d) => !knownDifficulties.contains(d)).toList()..sort();

    return HistoryStats._(
      total: total,
      last30Days: last30,
      last7Days: last7,
      byRound: {for (final r in rounds.keys.toList()..sort()) r: rounds[r]!},
      byRow: {for (final r in rows.keys.toList()..sort()) r: rows[r]!},
      byDifficulty: {
        for (final d in [...knownDifficulties, ...otherDifficulties]) d: ?difficulties[d],
      },
      strongest: strongest,
      weakest: weakest,
      bestStreak: games.fold(0, (best, game) => game.best > best ? game.best : best),
      recentGames: ([...games]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)))
          .take(recentGameCount).toList(),
    );
  }
}
