import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/data/local_question_source.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/clue_db_fixture.dart';

/// Returns [values] from nextInt, in order.
class ScriptedRandom implements Random {
  final List<int> values;
  ScriptedRandom(this.values);

  @override
  int nextInt(int max) {
    final value = values.removeAt(0);
    expect(value, lessThan(max));
    return value;
  }

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  double nextDouble() => throw UnimplementedError();
}

void main() {
  late Database db;

  setUp(() async => db = await createClueDb());
  tearDown(() => db.close());

  Future<LocalQuestionSource> open(List<int> randoms) async {
    final source = LocalQuestionSource.withDatabase(() async => db,
        random: ScriptedRandom(randoms));
    await source.open();
    return source;
  }

  test('reads the clue at the random id', () async {
    // nextInt(6) == 2 picks id 3.
    final q = await (await open([2])).randomQuestion();
    expect(q.sourceId, 'jwolle1');
    expect(q.key, '9003');
    expect(q.question, 'Clue 3');
    expect(q.answer, 'Response 3');
    expect(q.category, 'POTPOURRI');
    expect(q.round, 2);
    expect(q.value, 800);
    expect(q.dailyDoubleWager, 1500);
    expect(q.categoryComment, '(Alex: Each one is a mammal.)');
    expect(q.notes, isNull);
    expect(q.airDate, DateTime(1984, 9, 10));
    expect(q.raw['air_date'], '1984-09-10');
    expect(q.raw['category'], 'POTPOURRI');
  });

  test('every clue can be picked', () async {
    final source = await open([0, 1, 2, 3, 4, 5]);
    final keys = [for (var i = 0; i < 6; i++) (await source.randomQuestion()).key];
    expect(keys, ['-9001', '9002', '9003', '9004', '9005', '9006']);
  });

  test('Final Jeopardy has no value and regular clues no wager', () async {
    final source = await open([3, 0]);
    final finalClue = await source.randomQuestion();
    expect(finalClue.isFinalJeopardy, isTrue);
    expect(finalClue.value, isNull);
    expect(finalClue.notes, 'Tournament of Champions game 1.');
    final regular = await source.randomQuestion();
    expect(regular.value, 200);
    expect(regular.dailyDoubleWager, isNull);
    expect(regular.categoryComment, isNull);
  });

  test('a round filter returns the next match, wrapping around', () async {
    final source = await open([1, 5]);
    const finalOnly = QuestionFilter(rounds: {3});
    // From id 2, the next round-3 clue is id 4.
    expect((await source.randomQuestion(filter: finalOnly)).key, '9004');
    // From id 6 there is none, so it wraps to the start.
    expect((await source.randomQuestion(filter: finalOnly)).key, '9004');
  });

  test('a date filter is inclusive', () async {
    final source = await open([0, 5]);
    final filter = QuestionFilter(from: DateTime(2012, 9, 17), to: DateTime(2012, 9, 17));
    expect((await source.randomQuestion(filter: filter)).key, '9005');
    expect((await source.randomQuestion(filter: filter)).key, '9006');
  });

  test('no match is NoQuestionFound', () async {
    final source = await open([0, 0]);
    await expectLater(
        source.randomQuestion(filter: QuestionFilter(from: DateTime(2020))),
        throwsA(isA<NoQuestionFound>()));
    await expectLater(source.randomQuestion(filter: const QuestionFilter(rounds: {})),
        throwsA(isA<NoQuestionFound>()));
  });

  test('an empty database is NoQuestionFound', () async {
    await db.close();
    db = await createClueDb(clues: []);
    final source = await open([]);
    await expectLater(source.randomQuestion(), throwsA(isA<NoQuestionFound>()));
  });

  test('falls back to the default namespace', () async {
    await db.close();
    db = await createClueDb(namespace: null);
    final q = await (await open([0])).randomQuestion();
    expect(q.sourceId, LocalQuestionSource.defaultNamespace);
  });
}
