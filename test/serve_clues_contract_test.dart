import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quizapp/controller/question_repository.dart';
import 'package:quizapp/data/api_dialect.dart';
import 'package:quizapp/data/hidden_question_store.dart';
import 'package:quizapp/data/history_client.dart';
import 'package:quizapp/data/history_store.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/local_question_source.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/history.dart';
import 'package:quizapp/model/question.dart';
import 'package:quizapp/model/score.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Runs the app's HTTP source against the real tool/serve_clues.py, serving a
/// database built by tool/build_clue_db.py from the Python tests' sample TSV.
/// Skipped when python3 isn't available.
void main() {
  final hasPython = () {
    try {
      return Process.runSync('python3', ['--version']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }();
  final skip = hasPython ? false : 'python3 is not available';

  late Directory dir;
  late Process server;
  late Uri baseUrl;
  const token = 'contract-test';

  setUpAll(() async {
    if (!hasPython) return;
    dir = await Directory.systemTemp.createTemp('serve_clues_contract');
    final tsv = p.join(dir.path, 'sample.tsv');
    final db = p.join(dir.path, 'clues.db');
    await _run(['-c', 'import sys; from pathlib import Path; sys.path.insert(0, "tool"); '
        'from test_build_clue_db import SAMPLE_ROWS, write_tsv; '
        'write_tsv(Path(sys.argv[1]), SAMPLE_ROWS)', tsv]);
    await _run(['tool/build_clue_db.py', '--input', tsv, '--output', db, '--sha256', '']);

    server = await Process.start('python3', ['tool/serve_clues.py', '--db', db,
      '--reports', p.join(dir.path, 'reports.db'), '--history', p.join(dir.path, 'history.db'),
      '--port', '0', '--token', token, '--quiet']);
    server.stderr.transform(utf8.decoder).listen(stderr.write);
    final firstLine = await server.stdout.transform(utf8.decoder)
        .transform(const LineSplitter()).first.timeout(const Duration(seconds: 20));
    final port = RegExp(r':(\d+)/').firstMatch(firstLine)!.group(1);
    baseUrl = Uri.parse('http://127.0.0.1:$port');
  });

  tearDownAll(() async {
    if (!hasPython) return;
    server.kill();
    await server.exitCode;
    await dir.delete(recursive: true);
  });

  HttpQuestionSource api({String? withToken = token}) =>
      HttpQuestionSource(baseUrl: baseUrl, dialect: QuizApiDialect(), token: withToken);

  test('serves questions the app can parse', () async {
    final source = api();
    final q = await source.randomQuestion();
    expect(q.sourceId, 'jwolle1');
    expect(q.question, isNotEmpty);
    expect(q.answer, isNotEmpty);
    expect(q.round, isIn([1, 2, 3]));
    expect(q.airDate, isNotNull);
    await source.close();
  }, skip: skip);

  test('applies filters on the server', () async {
    final source = api();
    final finalClue = await source.randomQuestion(filter: const QuestionFilter(rounds: {3}));
    expect(finalClue.answer, 'St. Petersburg');
    expect(finalClue.isFinalJeopardy, isTrue);
    expect(finalClue.value, isNull);
    expect(finalClue.notes, 'Tournament of Champions game 1.');

    final dd = await source.randomQuestion(filter: const QuestionFilter(rounds: {2}));
    expect(dd.dailyDoubleWager, 1500);
    expect(dd.question, "It's the largest living land animal");

    await expectLater(source.randomQuestion(filter: QuestionFilter(from: DateTime(2020))),
        throwsA(isA<NoQuestionFound>()));
    await source.close();
  }, skip: skip);

  test('uses the same keys as the local database', () async {
    sqfliteFfiInit();
    final local = LocalQuestionSource.withDatabase(() => databaseFactoryFfi.openDatabase(
        p.join(dir.path, 'clues.db'), options: OpenDatabaseOptions(readOnly: true)));
    await local.open();
    final source = api();
    const finalOnly = QuestionFilter(rounds: {3});
    final fromLocal = await local.randomQuestion(filter: finalOnly);
    final fromApi = await source.randomQuestion(filter: finalOnly);
    expect((fromApi.sourceId, fromApi.key), (fromLocal.sourceId, fromLocal.key));
    await local.close();
    await source.close();
  }, skip: skip);

  test('a wrong token is Unauthorized', () async {
    final source = api(withToken: 'wrong');
    await expectLater(source.randomQuestion(), throwsA(isA<Unauthorized>()
        .having((e) => e.message, 'message', contains('rejected the access token'))));
    await source.close();
  }, skip: skip);

  // Last: it hides the only Final Jeopardy clue on the server.
  test('hiding a question reports it, and the server stops serving it', () async {
    final source = api();
    final repository = QuestionRepository(source: source,
        hiddenStore: InMemoryHiddenQuestionStore());
    final finalClue = await repository.next(filter: const QuestionFilter(rounds: {3}));
    await repository.hide(finalClue);
    // The report is sent in the background; wait for the server to drop it.
    final fresh = api();
    for (var i = 0; i < 50; i++) {
      try {
        await fresh.randomQuestion(filter: const QuestionFilter(rounds: {3}));
        await Future.delayed(const Duration(milliseconds: 100));
      } on NoQuestionFound {
        break;
      }
    }
    await expectLater(fresh.randomQuestion(filter: const QuestionFilter(rounds: {3})),
        throwsA(isA<NoQuestionFound>()));
    await repository.close();
    await fresh.close();
  }, skip: skip);

  group('score history', () {
    HistoryClient history({String? withToken = token}) =>
        HistoryClient(baseUrl: baseUrl, credentials: ApiCredentials(withToken));
    final game = newHistoryId();
    HistoryAnswer answer(String key, {required bool right}) => HistoryAnswer.of(
        Question(sourceId: 'jwolle1', key: key, question: 'Clue', answer: 'Response',
            category: 'BIOGRAPHIES', value: 400, round: 1, airDate: DateTime(2010, 1, 1)),
        id: newHistoryId(), game: game, right: right, at: DateTime(2026, 10, 13, 14, 35));

    test('the server says it keeps one', () async {
      expect(await history().keepsHistory(), isTrue);
    }, skip: skip);

    test('what the app sends comes back as sent, a change of mind replacing it', () async {
      final client = history();
      final start = (await client.fetch(after: 0)).next;
      final first = answer('1', right: true);
      final totals = HistoryGame.of(game, Score(answered: 1, right: 1, streak: 1, best: 1,
          dollars: 400, valued: 1, started: DateTime(2026, 10, 13)),
          now: DateTime(2026, 10, 13, 14, 35));
      await client.send(HistoryBatch(answers: [first, answer('2', right: false)],
          games: [totals]));
      var page = await client.fetch(after: start);
      expect(page.answers.first, first);
      expect(page.games, [totals]);
      expect(page.more, isFalse);

      final changed = HistoryAnswer.fromJson({...first.toJson(), 'right': false})!;
      await client.send(HistoryBatch(answers: [changed]));
      page = await client.fetch(after: page.next);
      expect(page.answers, [changed]);
    }, skip: skip);

    test('pages', () async {
      final client = history();
      final start = (await client.fetch(after: 0)).next;
      await client.send(HistoryBatch(answers: [
        for (var i = 0; i < 3; i++) answer('p$i', right: true),
      ]));
      final first = await client.fetch(after: start, limit: 2);
      expect((first.answers.length, first.more), (2, true));
      final second = await client.fetch(after: first.next, limit: 2);
      expect((second.answers.length, second.more), (1, false));
      expect(second.historyId, first.historyId);
    }, skip: skip);

    test('refuses what it cannot store, and needs the token', () async {
      final bad = HistoryAnswer.fromJson({...answer('x', right: true).toJson(), 'id': 'short'})!;
      await expectLater(history().send(HistoryBatch(answers: [bad])),
          throwsA(isA<HistoryRejected>()));
      await expectLater(history(withToken: null).fetch(after: 0),
          throwsA(isA<Unauthorized>()));
    }, skip: skip);
  });
}

Future<void> _run(List<String> args) async {
  final result = await Process.run('python3', args);
  if (result.exitCode != 0) {
    fail('python3 ${args.first} failed:\n${result.stdout}\n${result.stderr}');
  }
}
