import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:quizapp/config/source_choice.dart';
import 'package:quizapp/config/source_config.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';

/// Runs the app against the real tool/serve_clues.py serving the sample clue
/// database and a trivia database together (docs/combined-server-plan.md).
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
    dir = await Directory.systemTemp.createTemp('serve_multi_contract');
    final tsv = p.join(dir.path, 'sample.tsv');
    final clues = p.join(dir.path, 'clues.db');
    final trivia = p.join(dir.path, 'trivia.db');
    await _run(['-c', 'import sys; from pathlib import Path; sys.path.insert(0, "tool"); '
        'from test_build_clue_db import SAMPLE_ROWS, write_tsv; '
        'write_tsv(Path(sys.argv[1]), SAMPLE_ROWS)', tsv]);
    await _run(['tool/build_clue_db.py', '--input', tsv, '--output', clues, '--sha256', '']);
    await _run(['-c', 'import json, sys; from pathlib import Path; sys.path.insert(0, "tool"); '
        'import build_trivia_db; '
        'items = json.loads(Path("test/support/opentdb/random.json").read_text())["results"]; '
        'build_trivia_db.build(items, Path(sys.argv[1]), "2026-10-10", "https://opentdb.com")',
      trivia]);

    server = await Process.start('python3', ['tool/serve_clues.py', '--db', clues,
      '--db', trivia, '--reports', p.join(dir.path, 'reports.db'), '--port', '0',
      '--token', token, '--quiet']);
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

  SourceChooser chooser() {
    final config = SourceConfig.parse(source: 'api', apiUrl: baseUrl.toString(),
        apiDialect: 'quizapp', apiToken: token, allowHttp: true);
    final datasets = InMemoryServerDatasetStore();
    return SourceChooser(SourceChooser.buildOptions(config: config),
        store: InMemorySourceChoiceStore(),
        server: SourceChooser.configuredServer(config, store: datasets));
  }

  test('the app learns both databases and switches to trivia', () async {
    final sources = chooser();
    final clues = sources.current.create();
    // As the repository does before the first question.
    await clues.open();
    final clue = await clues.randomQuestion();
    expect(clue.sourceId, 'jwolle1');
    expect(clue.format, QuestionFormat.open);

    expect(sources.learn(clues.serverDatasets), isTrue);
    expect([for (final o in sources.options.take(2)) o.label], ['Jeopardy! clues', 'Trivia']);
    final trivia = (await sources.choose('server:trivia'))! as HttpQuestionSource;
    expect(trivia.baseUrl, baseUrl.resolve('/trivia/'));
    await trivia.open();
    final question = await trivia.randomQuestion();
    expect(question.sourceId, 'opentdb');
    expect(question.choices, contains(question.answer));
    expect(trivia.supportedFilters, {FilterKind.category, FilterKind.difficulty});

    // From trivia, the server still lists the same databases.
    expect(sources.learn(trivia.serverDatasets), isFalse);
    await clues.close();
    await trivia.close();
  }, skip: skip);

  test('a question hidden on trivia is reported there', () async {
    final sources = chooser();
    final clues = sources.current.create();
    await clues.open();
    sources.learn(clues.serverDatasets);
    final trivia = (await sources.choose('server:trivia'))!;
    await trivia.open();
    final question = await trivia.randomQuestion();
    expect(trivia.canReport(question), isTrue);
    await trivia.reportRemote(question);

    final response = await http.get(baseUrl.resolve('/trivia/v1/random?count=50'),
        headers: {'Authorization': 'Bearer $token'});
    final keys = {for (final q in json.decode(response.body)['questions']) q['key']};
    expect(keys, hasLength(49));
    expect(keys, isNot(contains(question.key)));
    await clues.close();
    await trivia.close();
  }, skip: skip);
}

Future<void> _run(List<String> args) async {
  final result = await Process.run('python3', args);
  if (result.exitCode != 0) {
    fail('python3 ${args.first} failed:\n${result.stdout}\n${result.stderr}');
  }
}
