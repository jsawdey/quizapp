import 'dart:convert';
import 'dart:io';
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
    // The range is ids 5-6, so the pick is nextInt(2).
    final source = await open([0, 1]);
    final filter = QuestionFilter(from: DateTime(2012, 9, 17), to: DateTime(2012, 9, 17));
    expect((await source.randomQuestion(filter: filter)).key, '9005');
    expect((await source.randomQuestion(filter: filter)).key, '9006');
  });

  group('a date range', () {
    // Three clues on each of ten dates, a year apart: ids 1-30 in date order,
    // with keys equal to ids.
    final dated = [
      for (var i = 0; i < 30; i++)
        FixtureClue(i + 1, '${2000 + i ~/ 3}-06-01', 'CATEGORY ${i ~/ 3}',
            i % 3 == 2 ? 3 : 1, i % 3 == 2 ? 0 : 200),
    ];

    setUp(() async {
      await db.close();
      db = await createClueDb(clues: dated);
    });

    test('picks from its own ids only, each equally likely', () async {
      // 2003-2005 is ids 10-18: nextInt(9) picks each of them once.
      final source = await open([for (var i = 0; i < 9; i++) i]);
      final filter = QuestionFilter(from: DateTime(2003), to: DateTime(2005, 12, 31));
      final keys = [for (var i = 0; i < 9; i++) (await source.randomQuestion(filter: filter)).key];
      expect(keys, [for (var id = 10; id <= 18; id++) '$id']);
    });

    test('can be open at either end', () async {
      final source = await open([0, 2, 0, 5]);
      final from2008 = QuestionFilter(from: DateTime(2008));
      expect((await source.randomQuestion(filter: from2008)).key, '25');
      expect((await source.randomQuestion(filter: from2008)).key, '27');
      final to2001 = QuestionFilter(to: DateTime(2001, 12, 31));
      expect((await source.randomQuestion(filter: to2001)).key, '1');
      expect((await source.randomQuestion(filter: to2001)).key, '6');
    });

    test('combined with rounds, wraps within the range', () async {
      // 2003-2005 is ids 10-18; Final Jeopardy is ids 12, 15 and 18.
      final source = await open([8, 1]);
      final filter = QuestionFilter(rounds: const {3},
          from: DateTime(2003), to: DateTime(2005, 12, 31));
      expect((await source.randomQuestion(filter: filter)).key, '18');
      expect((await source.randomQuestion(filter: filter)).key, '12');
      // From id 18 (the last), the next match wraps to the range's start.
      final regular = QuestionFilter(rounds: const {1},
          from: DateTime(2003), to: DateTime(2005, 12, 31));
      final wrapping = await open([8]);
      expect((await wrapping.randomQuestion(filter: regular)).key, '10');
    });

    test('with no games in it is NoQuestionFound', () async {
      final source = await open([]);
      for (final filter in [
        QuestionFilter(from: DateTime(2003, 7), to: DateTime(2004, 5)),
        QuestionFilter(to: DateTime(1999)),
        QuestionFilter(from: DateTime(2010)),
      ]) {
        await expectLater(source.randomQuestion(filter: filter),
            throwsA(isA<NoQuestionFound>()));
      }
    });
  });

  test('board rows match the shared examples, and Final Jeopardy passes', () async {
    // The same examples check Question.boardRow and serve_clues.py.
    final examples = (json.decode(File('test/support/board_rows.json').readAsStringSync())
        as List<dynamic>).cast<Map<String, dynamic>>()
      ..sort((a, b) => (a['air_date'] as String).compareTo(b['air_date'] as String));
    await db.close();
    db = await createClueDb(clues: [
      for (var i = 0; i < examples.length; i++)
        FixtureClue(i + 1, examples[i]['air_date'] as String, 'CATEGORY',
            examples[i]['round'] as int, examples[i]['value'] as int),
    ]);
    for (var row = 1; row <= 5; row++) {
      // Starting from every id finds every clue that matches.
      final source = await open([for (var i = 0; i < examples.length; i++) i]);
      final found = {
        for (var i = 0; i < examples.length; i++)
          (await source.randomQuestion(filter: QuestionFilter(boardRows: {row}))).key
      };
      expect(found, {
        for (var i = 0; i < examples.length; i++)
          if (examples[i]['row'] == row || examples[i]['round'] == 3) '${i + 1}'
      }, reason: 'row $row');
    }
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
