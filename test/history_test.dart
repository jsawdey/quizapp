import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/model/history.dart';
import 'package:quizapp/model/question.dart';
import 'package:quizapp/model/score.dart';

import 'support/fakes.dart';

void main() {
  final at = DateTime(2026, 10, 13, 14, 35, 10);

  HistoryAnswer of(Question question, {bool right = true}) =>
      HistoryAnswer.of(question, id: 'a' * 32, game: 'b' * 32, right: right, at: at);

  test('ids are 32 lowercase hex digits, and differ', () {
    final id = newHistoryId();
    expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(newHistoryId(), isNot(id));
    expect(newHistoryId(Random(1)), newHistoryId(Random(1)));
  });

  test('a clue keeps its round, row and value', () {
    final answer = of(fakeQuestion('7', sourceId: 'jwolle1', round: 2, value: 1200,
        airDate: DateTime(2010, 1, 1), category: 'POTENT POTABLES'));
    expect(answer.namespace, 'jwolle1');
    expect(answer.key, '7');
    expect(answer.category, 'POTENT POTABLES');
    expect(answer.format, QuestionFormat.open);
    expect((answer.round, answer.row, answer.value), (2, 3, 1200));
    expect(answer.dailyDouble, isFalse);
    expect(answer.difficulty, isNull);
    expect(answer.right, isTrue);
  });

  test('a Daily Double and Final Jeopardy', () {
    final dailyDouble = of(fakeQuestion('1', round: 1, value: 400,
        airDate: DateTime(2010, 1, 1), dailyDoubleWager: 2000));
    expect((dailyDouble.dailyDouble, dailyDouble.row), (true, 2));
    final finalJeopardy = of(fakeQuestion('2', round: 3, value: 0), right: false);
    expect((finalJeopardy.round, finalJeopardy.row, finalJeopardy.right), (3, null, false));
  });

  test('trivia keeps its difficulty and format', () {
    final answer = of(fakeQuestion('t', sourceId: 'opentdb', value: null,
        difficulty: 'hard', choices: const ['True', 'False'], answer: 'True'));
    expect(answer.format, QuestionFormat.trueFalse);
    expect((answer.round, answer.row, answer.value), (null, null, null));
    expect(answer.difficulty, 'hard');
  });

  test('times are kept in UTC with the offset of the device', () {
    final answer = of(fakeQuestion('1'));
    expect(answer.answeredAt.isUtc, isTrue);
    expect(answer.answeredAt, at.toUtc());
    expect(answer.utcOffset, at.timeZoneOffset.inMinutes);
    expect(answer.localDay, DateTime.utc(2026, 10, 13));
  });

  test("an answer's day is the day where it was played", () {
    HistoryAnswer answer(String utc, int offset) => HistoryAnswer(id: 'a' * 32,
        game: 'b' * 32, answeredAt: DateTime.parse(utc), utcOffset: offset,
        namespace: 'n', key: 'k', category: 'c', format: QuestionFormat.open, right: true);
    // 11:30 pm on the 13th in New York is 3:30 am on the 14th in UTC.
    expect(answer('2026-10-14T03:30:00Z', -240).localDay, DateTime.utc(2026, 10, 13));
    expect(answer('2026-10-13T20:00:00Z', 600).localDay, DateTime.utc(2026, 10, 14));
  });

  test('text is cut to what the server accepts', () {
    final answer = of(fakeQuestion('', category: 'x' * 400, difficulty: 'y' * 30));
    expect(answer.key, '?');
    expect(answer.category.length, 300);
    expect(answer.difficulty!.length, 20);
  });

  test('answers round-trip through JSON in the server form', () {
    final answer = of(fakeQuestion('7', sourceId: 'jwolle1', round: 2, value: 1200,
        airDate: DateTime(2010, 1, 1)), right: false);
    final json = answer.toJson();
    expect(json['format'], 'open');
    expect(json['answered_at'], endsWith('Z'));
    expect(json['row'], 3);
    expect(HistoryAnswer.fromJson(jsonDecode(jsonEncode(json))), answer);
  });

  test('answers that are not answers read as null', () {
    final json = of(fakeQuestion('1')).toJson();
    expect(HistoryAnswer.fromJson('x'), isNull);
    expect(HistoryAnswer.fromJson({...json, 'format': 'essay'}), isNull);
    expect(HistoryAnswer.fromJson({...json, 'right': 1}), isNull);
    expect(HistoryAnswer.fromJson({...json, 'answered_at': 'yesterday'}), isNull);
    expect(HistoryAnswer.fromJson({...json}..remove('game')), isNull);
  });

  test('a game takes the figures of a score', () {
    final score = Score(answered: 10, right: 7, streak: 2, best: 4, dollars: 4200,
        valued: 8, started: DateTime(2026, 10, 11));
    final game = HistoryGame.of('c' * 32, score, now: at);
    expect((game.answered, game.right, game.best, game.dollars, game.valued),
        (10, 7, 4, 4200, 8));
    expect(game.started, DateTime(2026, 10, 11));
    expect(game.updatedAt, at.toUtc());
    final json = game.toJson();
    expect(json['started'], '2026-10-11');
    expect(HistoryGame.fromJson(jsonDecode(jsonEncode(json))), game);
    expect(HistoryGame.fromJson({...json, 'best': 'four'}), isNull);
  });
}
