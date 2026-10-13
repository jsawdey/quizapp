import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/model/score.dart';

import 'support/fakes.dart';

void main() {
  final now = DateTime(2026, 10, 11, 21, 30);
  final clue = fakeQuestion('1', round: 1, value: 400);
  final trivia = fakeQuestion('2', value: null, choices: const ['A', 'B'], answer: 'A');

  Score play(List<bool> results, {Score from = Score.empty}) =>
      results.fold(from, (score, right) => score.record(clue, right: right, now: now));

  test('counts answered and right', () {
    final score = play([true, false, true]);
    expect(score.answered, 3);
    expect(score.right, 2);
  });

  test('a miss ends the streak, and best keeps the longest', () {
    final score = play([true, true, true, false, true]);
    expect(score.streak, 1);
    expect(score.best, 3);
    expect(play([true, true], from: score).best, 3);
    expect(play([true, true, true], from: score).best, 4);
  });

  test('a skip ends the streak and changes nothing else', () {
    final score = play([true, true, false, true, true]);
    final skipped = score.skipped();
    expect(skipped.streak, 0);
    expect(skipped, Score(answered: score.answered, right: score.right,
        best: score.best, dollars: score.dollars, valued: score.valued,
        started: score.started));
    expect(skipped.skipped(), same(skipped));
    expect(Score.empty.skipped(), Score.empty);
  });

  test('dollars add the value when right and subtract it when wrong', () {
    final score = play([true, true, false]);
    expect(score.dollars, 400);
    expect(score.valued, 3);
    expect(play([false, false]).dollars, -800);
  });

  test('a Daily Double adds its board value when right and costs nothing when wrong', () {
    final dailyDouble = fakeQuestion('3', round: 2, value: 1600, dailyDoubleWager: 3000);
    final right = Score.empty.record(dailyDouble, right: true, now: now);
    expect(right.dollars, 1600);
    final wrong = right.record(dailyDouble, right: false, now: now);
    expect(wrong.dollars, 1600);
    expect(wrong.valued, 2);
    expect(wrong.right, 1);
    expect(wrong.streak, 0);
  });

  test('Final Jeopardy and trivia count without dollars', () {
    final finalJeopardy = fakeQuestion('4', round: 3, value: 0);
    // Some sources give Final Jeopardy a value; it still isn't scored in dollars.
    final finalWithValue = fakeQuestion('5', round: 3, value: 1000);
    var score = Score.empty;
    for (final question in [finalJeopardy, finalWithValue, trivia]) {
      score = score.record(question, right: true, now: now);
    }
    score = score.record(trivia, right: false, now: now);
    expect(score.answered, 4);
    expect(score.right, 3);
    expect(score.dollars, 0);
    expect(score.valued, 0);
  });

  test('started is the day of the first result', () {
    final first = Score.empty.record(clue, right: false, now: now);
    expect(first.started, DateTime(2026, 10, 11));
    final later = first.record(clue, right: true, now: DateTime(2026, 10, 12, 9));
    expect(later.started, DateTime(2026, 10, 11));
    expect(Score.empty.skipped().started, isNull);
  });

  test('isEmpty', () {
    expect(Score.empty.isEmpty, isTrue);
    expect(const Score().isEmpty, isTrue);
    expect(play([false]).isEmpty, isFalse);
  });
}
