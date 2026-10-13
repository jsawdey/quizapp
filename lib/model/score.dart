import 'package:quizapp/model/question.dart';

/// The game being played: how many questions were answered and got right,
/// the streak, and the dollar score for Jeopardy clues.
///
/// Immutable; [record] and [skipped] return the new score. The rules are in
/// docs/scoring-plan.md (§2).
class Score {
  /// Questions scored, right or wrong. Skips don't count.
  final int answered;
  final int right;

  /// Right answers in a row, broken by a miss or a skip.
  final int streak;

  /// The highest [streak] this game has reached.
  final int best;

  /// The Coryat score: a clue's value added when right and subtracted when
  /// wrong, except that a wrong Daily Double costs nothing. Can go below 0.
  final int dollars;

  /// How many scored questions had a dollar value, right or wrong.
  final int valued;

  /// The day the game's first question was scored; null before that.
  final DateTime? started;

  const Score({this.answered = 0, this.right = 0, this.streak = 0, this.best = 0,
    this.dollars = 0, this.valued = 0, this.started});

  static const empty = Score();

  bool get isEmpty => this == empty;

  /// Counts [question] as got [right], on the day of [now] if it is the
  /// game's first. Final Jeopardy and questions without a value count, but
  /// not in [dollars].
  Score record(Question question, {required bool right, required DateTime now}) {
    final value = question.value;
    final hasValue = value != null && value > 0 && !question.isFinalJeopardy;
    final isDailyDouble = question.dailyDoubleWager != null;
    final streak = right ? this.streak + 1 : 0;
    return Score(
      answered: answered + 1,
      right: this.right + (right ? 1 : 0),
      streak: streak,
      best: streak > best ? streak : best,
      dollars: dollars + (!hasValue ? 0 : right ? value : isDailyDouble ? 0 : -value),
      valued: valued + (hasValue ? 1 : 0),
      started: started ?? DateTime(now.year, now.month, now.day),
    );
  }

  /// Moving on from a question without scoring it: the streak ends.
  Score skipped() => streak == 0
      ? this
      : Score(answered: answered, right: right, best: best, dollars: dollars,
          valued: valued, started: started);

  @override
  bool operator ==(Object other) =>
      other is Score && other.answered == answered && other.right == right &&
      other.streak == streak && other.best == best && other.dollars == dollars &&
      other.valued == valued && other.started == started;

  @override
  int get hashCode => Object.hash(answered, right, streak, best, dollars, valued, started);

  @override
  String toString() => 'Score($right/$answered, streak $streak, best $best, '
      '\$$dollars from $valued, started $started)';
}
