import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/controller/question_repository.dart';
import 'package:quizapp/data/hidden_question_store.dart';
import 'package:quizapp/main.dart';
import 'package:quizapp/ui/quiz_question/quiz_ui_library.dart';
import 'package:quizapp/data/clue_database.dart';
import 'package:quizapp/data/local_question_source.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Runs LocalQuestionSource against a database built by tool/build_clue_db.py,
/// when one exists. Skipped otherwise: the dataset can't be committed.
void main() {
  final file = File(LocalDataset.clues.assetPath);
  final skip = file.existsSync()
      ? false
      : 'No ${LocalDataset.clues.assetPath}; run python3 tool/build_clue_db.py to include this test.';

  late LocalQuestionSource source;

  setUpAll(() async {
    if (skip != false) return;
    sqfliteFfiInit();
    source = LocalQuestionSource.withDatabase(() => databaseFactoryFfi.openDatabase(
        file.absolute.path, options: OpenDatabaseOptions(readOnly: true)));
    await source.open();
  });

  tearDownAll(() async {
    if (skip == false) await source.close();
  });

  test('schema matches what the app reads', () async {
    final db = await databaseFactoryFfi.openDatabase(file.absolute.path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    final meta = Map.fromEntries((await db.rawQuery('SELECT key, value FROM meta'))
        .map((r) => MapEntry(r['key'] as String, r['value'] as String)));
    await db.close();
    expect(meta['schema_version'], '${ClueDatabase.supportedSchemaVersion}');
    expect(meta['dataset_namespace'], LocalQuestionSource.defaultNamespace);
    expect(File(LocalDataset.clues.versionAssetPath).existsSync(), isTrue);
  }, skip: skip);

  test('returns well-formed random clues', () async {
    final keys = <String>{};
    for (var i = 0; i < 200; i++) {
      final q = await source.randomQuestion();
      expect(q.question, isNotEmpty);
      expect(q.answer, isNotEmpty);
      expect(q.category, isNotEmpty);
      expect(q.round, isIn([1, 2, 3]));
      expect(q.airDate, isNotNull);
      expect(q.value == null, q.isFinalJeopardy);
      keys.add(q.key);
    }
    // 200 picks from ~544k clues should all be different.
    expect(keys.length, greaterThan(195));
  }, skip: skip);

  test('installs from the real asset bundle', () async {
    // Checks that pubspec.yaml bundles clues.db and clues.version where
    // ClueDatabase looks for them.
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('real_db_install');
    addTearDown(() => dir.delete(recursive: true));
    final installed = LocalQuestionSource(database: ClueDatabase(
        directory: () async => dir.path, databaseFactory: databaseFactoryFfi));
    await installed.open();
    expect((await installed.randomQuestion()).question, isNotEmpty);
    await installed.close();
    expect(File(p.join(dir.path, 'clues.db')).lengthSync(), file.lengthSync());
  }, skip: skip);

  test('filters by round and date', () async {
    for (var i = 0; i < 20; i++) {
      final q = await source.randomQuestion(filter: QuestionFilter(
          rounds: {3}, from: DateTime(2010), to: DateTime(2010, 12, 31)));
      expect(q.round, 3);
      expect(q.airDate!.year, 2010);
    }
  }, skip: skip);

  test('clue ids follow air date', () async {
    // LocalQuestionSource picks from a date range by id; see _idRange.
    final db = await databaseFactoryFfi.openDatabase(file.absolute.path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    addTearDown(db.close);
    final backwards = await db.rawQuery('''
        SELECT COUNT(*) AS n FROM clues a JOIN clues b ON b.id = a.id + 1
        WHERE b.game_id < a.game_id''');
    expect(backwards.first['n'], 0);
    final games = await db.rawQuery('''
        SELECT COUNT(*) AS n FROM games a JOIN games b ON b.id = a.id + 1
        WHERE b.air_date <= a.air_date''');
    expect(games.first['n'], 0);
  }, skip: skip);

  test('picks fairly and quickly within filters', () async {
    final range = QuestionFilter(from: DateTime(2010), to: DateTime(2014, 12, 31));
    final keys = <String>{};
    for (var i = 0; i < 200; i++) {
      final q = await source.randomQuestion(filter: range);
      expect(q.airDate!.year, inInclusiveRange(2010, 2014));
      keys.add(q.key);
    }
    // Before picks were limited to the range's ids, most of them returned the
    // range's first clue.
    expect(keys.length, greaterThan(190));

    const noFinal = QuestionFilter(rounds: {1, 2});
    final watch = Stopwatch()..start();
    for (var i = 0; i < 100; i++) {
      expect((await source.randomQuestion(filter: noFinal)).round, isIn([1, 2]));
    }
    // About 65 ms each when SQLite used the round index.
    expect(watch.elapsedMilliseconds / 100, lessThan(5));
  }, skip: skip);

  test('every Jeopardy and Double Jeopardy clue has a board row', () async {
    final db = await databaseFactoryFfi.openDatabase(file.absolute.path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    addTearDown(db.close);
    // Clue values doubled on 2001-11-26; see Question.boardRow.
    final misfits = await db.rawQuery('''
        SELECT COUNT(*) AS n FROM (
          SELECT c.value, CASE c.round WHEN 1 THEN 100 ELSE 200 END
                 * CASE WHEN g.air_date >= '2001-11-26' THEN 2 ELSE 1 END AS base
          FROM clues c JOIN games g ON g.id = c.game_id WHERE c.round IN (1, 2))
        WHERE value % base != 0 OR value / base NOT BETWEEN 1 AND 5''');
    expect(misfits.first['n'], 0);
  }, skip: skip);

  test('picks fairly from a board row', () async {
    const bottom = QuestionFilter(rounds: {1, 2}, boardRows: {5});
    final keys = <String>{};
    for (var i = 0; i < 200; i++) {
      final q = await source.randomQuestion(filter: bottom);
      expect(q.boardRow, 5);
      keys.add(q.key);
    }
    expect(keys.length, greaterThan(190));
  }, skip: skip);

  testWidgets('the app shows real clues and hides one', (WidgetTester tester) async {
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('real_app'));
    addTearDown(() => dir!.delete(recursive: true));
    final hidden = SqfliteHiddenQuestionStore(databaseFactory: databaseFactoryFfi,
        path: () async => p.join(dir!.path, 'user.db'));
    final repository = QuestionRepository(
      source: LocalQuestionSource(database: ClueDatabase(
          directory: () async => dir!.path, databaseFactory: databaseFactoryFfi)),
      hiddenStore: hidden,
    );
    addTearDown(() => tester.runAsync(repository.close));

    // Empty while the loading indicator is showing.
    String shownClue() {
      final text = find.descendant(
          of: find.byType(QuestionAnswerWidget), matching: find.byType(Text));
      return text.evaluate().isEmpty ? '' : tester.widget<Text>(text).data!;
    }

    // Database work is real I/O, which only happens outside the fake clock.
    Future<void> waitForClueOtherThan(String previous) async {
      for (var i = 0; i < 50 && shownClue() == previous; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
    }

    await tester.pumpWidget(QuizApp(repository: repository));
    await waitForClueOtherThan('');
    final first = shownClue();
    expect(first, isNotEmpty);

    await tester.tap(find.widgetWithText(TextButton, 'Hide Question'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide'));
    await waitForClueOtherThan(first);
    expect(shownClue(), isNot(first));
    expect(File(p.join(dir!.path, 'user.db')).existsSync(), isTrue);
  }, skip: skip != false);
}
