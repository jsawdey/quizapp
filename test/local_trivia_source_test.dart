import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/data/clue_database.dart';
import 'package:quizapp/data/local_question_source.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'local_question_source_test.dart' show ScriptedRandom;
import 'support/trivia_db_fixture.dart';

void main() {
  late Database db;

  setUp(() async => db = await createTriviaDb());
  tearDown(() => db.close());

  Future<LocalQuestionSource> open(List<int> randoms) async {
    final source = LocalQuestionSource.withDatabase(() async => db,
        dataset: LocalDataset.trivia, random: ScriptedRandom(randoms));
    await source.open();
    return source;
  }

  test('reads the question at the random id, with its choices', () async {
    // nextInt(5) == 2 picks id 3.
    final q = await (await open([2])).randomQuestion();
    expect(q.sourceId, 'opentdb');
    expect(q.key, 'g1');
    expect(q.question, 'Question g1');
    expect(q.answer, 'Bern');
    expect(q.category, 'Geography');
    expect(q.difficulty, 'easy');
    expect(q.choices, ['Zürich', 'Wien', 'Bern', 'Frankfurt']);
    expect(q.format, QuestionFormat.multipleChoice);
    expect(q.value, isNull);
    expect(q.round, isNull);
    expect(q.raw['category'], 'Geography');
  });

  test('offers category and difficulty filters, its categories and its credit', () async {
    final source = await open([]);
    expect(source.supportedFilters, {FilterKind.category, FilterKind.difficulty});
    expect(source.description, 'the trivia database');
    expect(await source.filterCategories(), ['Art', 'Geography', 'History']);
    expect(source.attribution, contains('Open Trivia Database'));
  });

  test('picks fairly among the questions a filter matches', () async {
    // Art or History, hard: a2 and h1. Offsets 0 and 1, counted once.
    final source = await open([0, 1, 1]);
    const filter = QuestionFilter(categories: {'Art', 'History'}, difficulties: {'hard'});
    expect((await source.randomQuestion(filter: filter)).key, 'a2');
    expect((await source.randomQuestion(filter: filter)).key, 'h1');
    expect((await source.randomQuestion(filter: filter)).format, QuestionFormat.trueFalse);

    final easy = await open([1]);
    expect((await easy.randomQuestion(
        filter: const QuestionFilter(difficulties: {'easy'}))).key, 'g1');
  });

  test('a filter nothing matches is NoQuestionFound', () async {
    final source = await open([]);
    await expectLater(source.randomQuestion(filter: const QuestionFilter(
        categories: {'Geography'}, difficulties: {'hard'})), throwsA(isA<NoQuestionFound>()));
    await expectLater(source.randomQuestion(filter: const QuestionFilter(
        categories: {'Knitting'})), throwsA(isA<NoQuestionFound>()));
  });

  test('choices that can\'t be offered play as a flip card', () async {
    await db.close();
    db = await createTriviaDb(questions: const [
      FixtureTrivia('x', 'Art', 'easy', 'Missing', ['A', 'B']),
    ]);
    final q = await (await open([0])).randomQuestion();
    expect(q.choices, isNull);
    expect(q.answer, 'Missing');
  });

  test('a clue source lists no categories', () async {
    final source = LocalQuestionSource(dataset: LocalDataset.clues);
    expect(source.supportedFilters, isNot(contains(FilterKind.category)));
    expect(LocalQuestionSource(dataset: LocalDataset.trivia).description,
        'the trivia database');
  });

  group('the real trivia.db', () {
    final file = File(LocalDataset.trivia.assetPath);
    final skip = file.existsSync()
        ? false
        : 'No ${LocalDataset.trivia.assetPath}; run python3 tool/build_trivia_db.py '
            'to include these tests.';

    test('matches the schema and plays every kind of question', () async {
      sqfliteFfiInit();
      final real = await databaseFactoryFfi.openDatabase(file.absolute.path,
          options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
      final source = LocalQuestionSource.withDatabase(() async => real,
          dataset: LocalDataset.trivia, random: Random(7));
      await source.open();
      final categories = await source.filterCategories();
      expect(categories.length, greaterThan(20));
      for (var i = 0; i < 200; i++) {
        final q = await source.randomQuestion();
        expect(q.choices, contains(q.answer));
        expect(q.difficulty, isIn(QuestionFilter.allDifficulties));
      }
      final filter = QuestionFilter(categories: {categories.first}, difficulties: {'hard'});
      for (var i = 0; i < 20; i++) {
        expect(filter.matches(await source.randomQuestion(filter: filter)), isTrue);
      }
      await source.close();
    }, skip: skip);
  });
}
