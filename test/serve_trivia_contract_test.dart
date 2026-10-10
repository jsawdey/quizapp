import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:quizapp/data/api_dialect.dart';
import 'package:quizapp/data/clue_database.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/local_question_source.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Runs the app's HTTP source against the real tool/serve_clues.py, serving a
/// trivia database built by tool/build_trivia_db.py from the saved OpenTDB
/// responses. Skipped when python3 isn't available.
void main() {
  final hasPython = () {
    try {
      return Process.runSync('python3', ['--version']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }();
  final skip = hasPython ? false : 'python3 is not available';

  const musicals = 'Entertainment: Musicals & Theatres';
  late Directory dir;
  late String db;
  late Process server;
  late Uri baseUrl;

  setUpAll(() async {
    if (!hasPython) return;
    dir = await Directory.systemTemp.createTemp('serve_trivia_contract');
    db = p.join(dir.path, 'trivia.db');
    await _run(['-c', 'import json, sys; from pathlib import Path; sys.path.insert(0, "tool"); '
        'import build_trivia_db; '
        'items = [i for name in ("random.json", "random_small_pool.json") '
        'for i in json.loads(Path("test/support/opentdb", name).read_text())["results"]]; '
        'build_trivia_db.build(items, Path(sys.argv[1]), "2026-10-10", "https://opentdb.com")',
      db]);
    server = await Process.start('python3', ['tool/serve_clues.py', '--db', db,
      '--reports', p.join(dir.path, 'reports.db'), '--port', '0', '--quiet']);
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

  Future<HttpQuestionSource> api() async {
    final source = HttpQuestionSource(baseUrl: baseUrl, dialect: QuizApiDialect());
    await source.open();
    return source;
  }

  test('says it serves trivia, with its filters, categories and credit', () async {
    final source = await api();
    expect(source.supportedFilters, {FilterKind.category, FilterKind.difficulty});
    expect(await source.filterCategories(), contains(musicals));
    expect(source.attribution, contains('Open Trivia Database'));
    await source.close();
  }, skip: skip);

  test('serves multiple-choice questions the app can play', () async {
    final source = await api();
    final q = await source.randomQuestion();
    expect(q.sourceId, 'opentdb');
    expect(q.choices, contains(q.answer));
    expect(q.format, isNot(QuestionFormat.open));
    expect(q.difficulty, isIn(QuestionFilter.allDifficulties));
    await source.close();
  }, skip: skip);

  test('filters on the server, with the live API\'s keys', () async {
    final source = await api();
    const filter = QuestionFilter(categories: {musicals}, difficulties: {'hard'});
    // One batch holds every match.
    final dialect = QuizApiDialect();
    final response = await http.get(dialect.randomUri(baseUrl, 50, filter));
    final served = {
      for (final q in dialect.parseRandom(json.decode(response.body), baseUrl)) q.key,
    };
    expect(filter.matches(await source.randomQuestion(filter: filter)), isTrue);
    // The same 11 questions, keyed as OpenTdbDialect keys them live, so a
    // question hidden on one is hidden on the other.
    final live = OpenTdbDialect().parseRandom(
        json.decode(File('test/support/opentdb/random_small_pool.json').readAsStringSync()),
        Uri.parse('https://opentdb.com'));
    expect(served, {for (final q in live) q.key});
    await expectLater(source.randomQuestion(filter: const QuestionFilter(
        categories: {'Knitting'})), throwsA(isA<NoQuestionFound>()));
    await source.close();
  }, skip: skip);

  test('the local source reads the same database the same way', () async {
    sqfliteFfiInit();
    final local = LocalQuestionSource.withDatabase(() => databaseFactoryFfi.openDatabase(
        db, options: OpenDatabaseOptions(readOnly: true)), dataset: LocalDataset.trivia);
    await local.open();
    final source = await api();
    expect(await local.filterCategories(), await source.filterCategories());
    expect(local.attribution, source.attribution);
    const filter = QuestionFilter(categories: {musicals}, difficulties: {'hard'});
    final fromLocal = await local.randomQuestion(filter: filter);
    expect(fromLocal.sourceId, 'opentdb');
    expect(filter.matches(fromLocal), isTrue);
    await local.close();
    await source.close();
  }, skip: skip);
}

Future<void> _run(List<String> args) async {
  final result = await Process.run('python3', args);
  if (result.exitCode != 0) {
    fail('python3 ${args.first} failed:\n${result.stdout}\n${result.stderr}');
  }
}
