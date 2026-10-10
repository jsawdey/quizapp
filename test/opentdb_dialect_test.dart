import 'dart:async';
import 'dart:convert' show json;
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quizapp/data/api_dialect.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';

/// Real responses saved by tool/capture_opentdb.py.
String fixture(String name) => File('test/support/opentdb/$name').readAsStringSync();

Object? fixtureJson(String name) => json.decode(fixture(name));

/// The HTTP status each fixture was captured with.
int fixtureStatus(String name) {
  final manifest = fixtureJson('manifest.json') as Map<String, dynamic>;
  return (manifest['files'] as Map<String, dynamic>)[name]['status'] as int;
}

/// [name] as the live API sent it, with its HTTP status.
http.Response fixtureResponse(String name) => http.Response.bytes(
    File('test/support/opentdb/$name').readAsBytesSync(), fixtureStatus(name),
    headers: {'content-type': 'application/json'});

void main() {
  final base = Uri.parse('https://opentdb.com');
  const placeholderToken = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  group('OpenTdbDialect', () {
    late OpenTdbDialect dialect;
    setUp(() => dialect = OpenTdbDialect());

    test('the fixtures cover what the dialect handles', () {
      final manifest = fixtureJson('manifest.json') as Map<String, dynamic>;
      final files = manifest['files'] as Map<String, dynamic>;
      expect({for (final f in files.values) (f as Map)['response_code']},
          containsAll([0, 1, 2, 3, 4, 5]));
      expect(fixtureStatus('code5_rate_limit.json'), 429);
    });

    test('asks for 50 URL-encoded questions, with the token once it has one', () {
      expect(dialect.batchSize, 50);
      expect(dialect.randomUri(base, 500, QuestionFilter.any).toString(),
          'https://opentdb.com/api.php?amount=50&encode=url3986');
      dialect.token = 'abc';
      expect(dialect.randomUri(base, 10, QuestionFilter.any).queryParameters,
          {'amount': '10', 'encode': 'url3986', 'token': 'abc'});
    });

    test('open requests a session token', () async {
      final asked = <Uri>[];
      await dialect.open((uri) async {
        asked.add(uri);
        return fixtureJson('token_request.json');
      }, base);
      expect(asked.single.toString(), 'https://opentdb.com/api_token.php?command=request');
      expect(dialect.token, placeholderToken);

      await expectLater(dialect.open((_) async => {'response_code': 3}, base),
          throwsA(isA<FormatException>()));
    });

    test('parses a real page of questions', () {
      final questions = dialect.parseRandom(fixtureJson('random.json'), base);
      expect(questions, hasLength(50));
      for (final q in questions) {
        expect(q.sourceId, 'opentdb');
        expect(q.key, matches(RegExp(r'^[0-9a-f]{16}$')));
        expect(q.choices, contains(q.answer));
        expect(q.difficulty, isIn(['easy', 'medium', 'hard']));
        expect(q.value, isNull);
        expect(q.round, isNull);
        expect(q.question, isNot(contains('%')), reason: q.question);
      }
      expect(questions.map((q) => q.key).toSet(), hasLength(50));
      expect(questions.where((q) => q.format == QuestionFormat.trueFalse), hasLength(10));
      expect(questions.where((q) => q.format == QuestionFormat.multipleChoice), hasLength(40));
      expect(questions.where((q) => q.format == QuestionFormat.trueFalse)
          .map((q) => q.choices), everyElement(['True', 'False']));
    });

    test('decodes, trims and keys questions as Python\'s hashlib does', () {
      // Keys and orders computed independently with Python's hashlib.
      final questions = dialect.parseRandom(fixtureJson('random.json'), base);
      final rolex = questions[0];
      expect(rolex.category, 'General Knowledge');
      expect(rolex.question, 'Rolex is a company that specializes in what type of product?');
      expect(rolex.answer, 'Watches');
      expect(rolex.key, 'faa6fa673a4b42d5');
      expect(rolex.choices, ['Cars', 'Sports equipment', 'Computers', 'Watches']);
      expect(rolex.raw['question'], rolex.question);

      final bern = questions[17];
      expect(bern.key, 'abf1c8e425dedc04');
      expect(bern.choices, ['Zürich', 'Wien', 'Bern', 'Frankfurt']);
      expect(bern.category, 'Geography');

      // Sent as "Ammonia%20" with a stray space.
      final water = questions[41];
      expect(water.key, '5fbea8159f0e84ea');
      expect(water.category, 'Science & Nature');
      expect(water.choices, ['Laughing Gas', 'Water', 'Methane', 'Ammonia']);
    });

    test('the choice order is stable and the answer isn\'t always first', () {
      final first = dialect.parseRandom(fixtureJson('random.json'), base);
      final again = OpenTdbDialect().parseRandom(fixtureJson('random.json'), base);
      expect([for (final q in again) q.choices], [for (final q in first) q.choices]);
      final multiple = first.where((q) => q.format == QuestionFormat.multipleChoice);
      final answerFirst = multiple.where((q) => q.choices!.first == q.answer).length;
      expect(answerFirst, 9);
      expect(multiple.length, 40);
    });

    test('maps each response code', () {
      expect(() => dialect.parseRandom(fixtureJson('code1_no_results.json'), base),
          throwsA(isA<NoQuestionFound>()));
      expect(() => dialect.parseRandom(fixtureJson('code2_invalid_parameter.json'), base),
          throwsA(isA<SourceUnavailable>()));
      expect(() => dialect.parseRandom(fixtureJson('code3_token_not_found.json'), base),
          throwsA(isA<SessionExpired>()));
      expect(() => dialect.parseRandom(fixtureJson('code4_token_empty.json'), base),
          throwsA(isA<SessionExpired>()));
      expect(() => dialect.parseRandom(fixtureJson('code5_rate_limit.json'), base),
          throwsA(isA<SourceUnavailable>().having(
              (e) => e.message, 'message', 'opentdb.com is busy; try again in a few seconds.')));
      expect(() => dialect.parseRandom({'response_code': 99}, base),
          throwsA(isA<FormatException>()));
      expect(() => dialect.parseRandom([], base), throwsA(isA<FormatException>()));
      expect(() => dialect.parseRandom({'response_code': 0}, base),
          throwsA(isA<FormatException>()));
    });

    test('skips items that don\'t parse', () {
      Map<String, dynamic> item(Map<String, dynamic> changes) => {
            'type': 'multiple', 'difficulty': 'easy', 'category': 'C',
            'question': 'Q%3F', 'correct_answer': 'A',
            'incorrect_answers': ['B', 'C', 'D'], ...changes};
      final questions = dialect.parseRandom({'response_code': 0, 'results': [
        item({}),
        item({'type': 'picture'}),
        item({'question': 'bad %zz encoding'}),
        item({'correct_answer': '%20'}),
        item({'incorrect_answers': ['A', 'B', 'C']}),
        item({'incorrect_answers': ['B', 3]}),
        item({'type': 'boolean', 'correct_answer': 'Maybe', 'incorrect_answers': ['False']}),
        'not an item',
      ]}, base);
      expect(questions.map((q) => q.question), ['Q?']);
    });

    test('credits Open Trivia Database and supports no reports', () {
      expect(dialect.attribution, contains('CC BY-SA 4.0'));
      expect(dialect.supportedFilters, {FilterKind.category, FilterKind.difficulty});
      expect(dialect.supportsReport, isFalse);
      expect(apiDialects['opentdb']!(), isA<OpenTdbDialect>());
    });
  });

  group('OpenTdbDialect filters', () {
    late List<Uri> asked;
    late OpenTdbDialect dialect;

    /// Answers like the live API; every category counts as the saved one.
    Future<Object?> get(Uri uri) async {
      asked.add(uri);
      return switch (uri.path) {
        '/api_category.php' => fixtureJson('categories.json'),
        '/api_count.php' => fixtureJson('count_small_pool.json'),
        _ => throw StateError('unexpected $uri'),
      };
    }

    setUp(() {
      asked = [];
      dialect = OpenTdbDialect(random: Random(1));
    });

    const musicals = 'Entertainment: Musicals & Theatres';

    test('lists the categories alphabetically, asking once', () async {
      final names = await dialect.filterCategories(get, base);
      expect(names, hasLength(24));
      expect(names.take(3), ['Animals', 'Art', 'Celebrities']);
      expect(names, contains(musicals));
      await dialect.filterCategories(get, base);
      expect(asked, hasLength(1));
    });

    test('asks for no more than a small category holds', () async {
      // Musicals & Theatres: 36 questions, 11 of them hard.
      final filter = const QuestionFilter(categories: {musicals});
      await dialect.prepare(get, base, filter);
      expect(asked.map((u) => u.toString()), [
        'https://opentdb.com/api_category.php',
        'https://opentdb.com/api_count.php?category=13',
      ]);
      expect(dialect.randomUri(base, 50, filter).queryParameters,
          {'amount': '36', 'category': '13', 'encode': 'url3986'});

      const hard = QuestionFilter(categories: {musicals}, difficulties: {'hard'});
      await dialect.prepare(get, base, hard);
      // Counted already.
      expect(asked, hasLength(2));
      expect(dialect.randomUri(base, 50, hard).queryParameters,
          {'amount': '11', 'category': '13', 'difficulty': 'hard', 'encode': 'url3986'});
    });

    test('draws from each category and difficulty by size', () async {
      const filter = QuestionFilter(categories: {musicals, 'Art'},
          difficulties: {'easy', 'medium'});
      await dialect.prepare(get, base, filter);
      final picks = <String>{};
      for (var i = 0; i < 100; i++) {
        final query = dialect.randomUri(base, 50, filter).queryParameters;
        picks.add('${query['category']} ${query['difficulty']} ${query['amount']}');
      }
      // Art (25) counts as the saved Musicals & Theatres counts here.
      expect(picks, {'13 easy 11', '13 medium 14', '25 easy 11', '25 medium 14'});
    });

    test('a difficulty alone needs no counts', () async {
      const filter = QuestionFilter(difficulties: {'hard'});
      await dialect.prepare(get, base, filter);
      expect(asked, isEmpty);
      expect(dialect.randomUri(base, 50, filter).queryParameters,
          {'amount': '50', 'difficulty': 'hard', 'encode': 'url3986'});
    });

    test('an unknown or empty category is NoQuestionFound', () async {
      const unknown = QuestionFilter(categories: {'Knitting'});
      await dialect.prepare(get, base, unknown);
      expect(() => dialect.randomUri(base, 50, unknown), throwsA(isA<NoQuestionFound>()));
    });

    test('a bad category list is a FormatException', () async {
      await expectLater(dialect.filterCategories((_) async => {'nope': 1}, base),
          throwsA(isA<FormatException>()));
    });
  });

  group('HttpQuestionSource with OpenTDB', () {
    late List<Uri> requests;
    late List<Duration> waits;
    late DateTime now;

    HttpQuestionSource sourceWith(FutureOr<http.Response> Function(Uri) handler) {
      requests = [];
      waits = [];
      now = DateTime(2026, 10, 10, 12);
      return HttpQuestionSource(
        baseUrl: base,
        dialect: OpenTdbDialect(),
        client: MockClient((request) async {
          requests.add(request.url);
          return handler(request.url);
        }),
        now: () => now,
        delay: (wait) async {
          waits.add(wait);
          now = now.add(wait);
        },
      );
    }

    /// Answers like the live API: a token, then pages of questions.
    FutureOr<http.Response> api(Uri uri) => uri.path == '/api_token.php'
        ? fixtureResponse('token_request.json')
        : fixtureResponse('random.json');

    test('gets a token on open and sends it with a batch of 50', () async {
      final source = sourceWith(api);
      await source.open();
      final question = await source.randomQuestion();
      expect(question.key, 'faa6fa673a4b42d5');
      expect(requests.map((u) => u.path), ['/api_token.php', '/api.php']);
      expect(requests.last.queryParameters,
          {'amount': '50', 'encode': 'url3986', 'token': placeholderToken});
      expect(source.attribution, contains('Open Trivia Database'));
      expect(source.supportsRemoteReport, isFalse);
    });

    test('a failed token request fails open', () async {
      final down = sourceWith((_) => http.Response('', 503));
      await expectLater(down.open(), throwsA(isA<SourceUnavailable>()));

      final odd = sourceWith((_) => http.Response('{"response_code": 3}', 200));
      await expectLater(odd.open(), throwsA(isA<SourceUnavailable>()
          .having((e) => e.message, 'message', contains('unexpected response'))));
    });

    test('an expired or used-up token is replaced once', () async {
      for (final expired in ['code3_token_not_found.json', 'code4_token_empty.json']) {
        var batches = 0;
        final source = sourceWith((uri) {
          if (uri.path == '/api_token.php') return fixtureResponse('token_request.json');
          return fixtureResponse(batches++ == 0 ? expired : 'random.json');
        });
        await source.open();
        expect((await source.randomQuestion()).key, 'faa6fa673a4b42d5', reason: expired);
        expect(requests.map((u) => u.path),
            ['/api_token.php', '/api.php', '/api_token.php', '/api.php'], reason: expired);
      }
    });

    test('a token that keeps failing is SourceUnavailable', () async {
      final source = sourceWith((uri) => uri.path == '/api_token.php'
          ? fixtureResponse('token_request.json')
          : fixtureResponse('code3_token_not_found.json'));
      await source.open();
      await expectLater(source.randomQuestion(), throwsA(isA<SourceUnavailable>()
          .having((e) => e.message, 'message', contains('session'))));
      expect(requests.where((u) => u.path == '/api.php'), hasLength(2));
    });

    test('HTTP 429 says the API is busy', () async {
      final source = sourceWith((_) => fixtureResponse('code5_rate_limit.json'));
      await expectLater(source.randomQuestion(), throwsA(isA<SourceUnavailable>().having(
          (e) => e.message, 'message', 'opentdb.com is busy; try again in a few seconds.')));
    });

    test('no questions is NoQuestionFound', () async {
      final source = sourceWith((_) => fixtureResponse('code1_no_results.json'));
      await expectLater(source.randomQuestion(), throwsA(isA<NoQuestionFound>()));
    });

    test('batches go out at least 5 seconds apart; token requests don\'t wait', () async {
      var batches = 0;
      final source = sourceWith((uri) {
        if (uri.path == '/api_token.php') return fixtureResponse('token_request.json');
        return fixtureResponse(batches++ == 0 ? 'code4_token_empty.json' : 'random.json');
      });
      await source.open();
      await source.randomQuestion();
      // The first batch went at once; the retry after the new token waited.
      expect(waits, [const Duration(seconds: 5)]);

      // The background refill comes long after the last batch.
      now = now.add(const Duration(minutes: 5));
      for (var i = 0; i < 47; i++) {
        await source.randomQuestion();
      }
      await pumpEventQueue();
      expect(requests.where((u) => u.path == '/api.php'), hasLength(3));
      expect(waits, hasLength(1));
    });

    test('filters by category: counts it, then asks for what it holds', () async {
      final source = sourceWith((uri) => switch (uri.path) {
            '/api_token.php' => fixtureResponse('token_request.json'),
            '/api_category.php' => fixtureResponse('categories.json'),
            '/api_count.php' => fixtureResponse('count_small_pool.json'),
            _ => fixtureResponse('random_small_pool.json'),
          });
      await source.open();
      expect(await source.filterCategories(), contains('Entertainment: Musicals & Theatres'));
      const filter = QuestionFilter(categories: {'Entertainment: Musicals & Theatres'},
          difficulties: {'hard'});
      final question = await source.randomQuestion(filter: filter);
      expect(question.category, 'Entertainment: Musicals & Theatres');
      expect(question.difficulty, 'hard');
      expect(requests.map((u) => u.path),
          ['/api_token.php', '/api_category.php', '/api_count.php', '/api.php']);
      expect(requests.last.queryParameters['amount'], '11');
      // Counted once per category.
      await source.randomQuestion(filter: const QuestionFilter(
          categories: {'Entertainment: Musicals & Theatres'}));
      expect(requests.where((u) => u.path == '/api_count.php'), hasLength(1));
    });

    test('two batches asked for at once go out 5 seconds apart', () async {
      final source = sourceWith(api);
      // Both find the buffer empty, so both fetch.
      await Future.wait([source.randomQuestion(), source.randomQuestion()]);
      expect(requests, hasLength(2));
      expect(waits, [const Duration(seconds: 5)]);
    });
  });
}
