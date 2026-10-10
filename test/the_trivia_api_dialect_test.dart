import 'dart:async';
import 'dart:convert' show json;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quizapp/data/api_dialect.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';

/// Real responses saved by tool/capture_trivia_api.py.
File fixtureFile(String name) => File('test/support/the_trivia_api/$name');

Object? fixtureJson(String name) => json.decode(fixtureFile(name).readAsStringSync());

/// [name] as the live API sent it, with its HTTP status.
http.Response fixtureResponse(String name) {
  final manifest = fixtureJson('manifest.json') as Map<String, dynamic>;
  final status = (manifest['files'] as Map<String, dynamic>)[name]['status'] as int;
  return http.Response.bytes(fixtureFile(name).readAsBytesSync(), status,
      headers: {'content-type': name.endsWith('.json')
          ? 'application/json; charset=utf-8' : 'text/plain; charset=utf-8'});
}

void main() {
  final base = Uri.parse('https://the-trivia-api.com');

  /// A dialect that has read the real category list.
  Future<TheTriviaApiDialect> opened() async {
    final dialect = TheTriviaApiDialect();
    await dialect.open((_) async => fixtureJson('categories.json'), base);
    return dialect;
  }

  group('TheTriviaApiDialect', () {
    test('open reads the category list', () async {
      final dialect = TheTriviaApiDialect();
      final asked = <Uri>[];
      await dialect.open((uri) async {
        asked.add(uri);
        return fixtureJson('categories.json');
      }, base);
      expect(asked.single.toString(), 'https://the-trivia-api.com/v2/categories');
      final names = await dialect.filterCategories((_) async => null, base);
      expect(names, hasLength(10));
      expect(names.take(3), ['Arts & Literature', 'Film & TV', 'Food & Drink']);

      await expectLater(TheTriviaApiDialect().open((_) async => [], base),
          throwsA(isA<FormatException>()));
    });

    test('asks for up to 50, with every slug of each chosen category', () async {
      final dialect = await opened();
      expect(dialect.batchSize, 50);
      expect(dialect.randomUri(base, 500, QuestionFilter.any).toString(),
          'https://the-trivia-api.com/v2/questions?limit=50');
      // 0 would bring hundreds.
      expect(dialect.randomUri(base, 0, QuestionFilter.any).queryParameters['limit'], '1');
      final uri = dialect.randomUri(base, 50, const QuestionFilter(
          categories: {'Geography', 'Film & TV'}, difficulties: {'hard', 'easy'}));
      expect(uri.queryParameters, {
        'limit': '50',
        'categories': 'movies,film,film_and_tv,geography',
        'difficulties': 'easy,hard',
      });
    });

    test('parses a real page into multiple-choice questions', () async {
      final questions = (await opened()).parseRandom(fixtureJson('questions.json'), base);
      expect(questions, hasLength(50));
      final items = (fixtureJson('questions.json') as List).cast<Map<String, dynamic>>();
      for (final (i, q) in questions.indexed) {
        expect(q.sourceId, 'the-trivia-api');
        expect(q.key, items[i]['id']);
        expect(q.format, QuestionFormat.multipleChoice);
        expect(q.choices, hasLength(4));
        expect(q.choices, contains(q.answer));
        expect(q.difficulty, isIn(QuestionFilter.allDifficulties));
        // Display names, not slugs.
        expect(q.category, isNot(contains('_')), reason: q.category);
        for (final text in [q.question, ...q.choices!]) {
          expect(text, text.trim(), reason: 'untrimmed: "$text"');
        }
      }
      // Stable, and not always with the answer first.
      final again = (await opened()).parseRandom(fixtureJson('questions.json'), base);
      expect([for (final q in again) q.choices], [for (final q in questions) q.choices]);
      expect(questions.where((q) => q.choices!.first == q.answer).length,
          inInclusiveRange(5, 25));
    });

    test('trims spaces and no-break spaces', () async {
      final questions = (await opened()).parseRandom([
        {'id': 'x', 'type': 'text_choice', 'category': 'geography', 'difficulty': 'Easy',
          'question': {'text': 'Which river flows through Paris? '},
          'correctAnswer': 'The Seine ', 'incorrectAnswers': ['Loire', 'Rhône', 'Somme']},
      ], base);
      expect(questions.single.question, 'Which river flows through Paris?');
      expect(questions.single.answer, 'The Seine');
      expect(questions.single.choices, contains('The Seine'));
      expect(questions.single.category, 'Geography');
      expect(questions.single.difficulty, 'easy');
    });

    test('a filtered page holds only what was asked for', () async {
      final dialect = await opened();
      const filter = QuestionFilter(categories: {'Geography', 'Music'}, difficulties: {'hard'});
      final questions = dialect.parseRandom(fixtureJson('questions_filtered.json'), base);
      expect(questions, hasLength(20));
      expect(questions.every(filter.matches), isTrue);
      // A small category comes back short, not empty.
      expect(dialect.parseRandom(fixtureJson('questions_small_pool.json'), base).length,
          inExclusiveRange(0, 50));
    });

    test('an unknown category is ignored by the API, so the filter must catch it', () async {
      final questions = (await opened())
          .parseRandom(fixtureJson('questions_unknown_category.json'), base);
      expect(questions.map((q) => q.category).toSet(), {'General Knowledge'});
      expect(questions.any(const QuestionFilter(categories: {'Knitting'}).matches), isFalse);
    });

    test('skips what it can\'t play', () async {
      Map<String, dynamic> item(Map<String, dynamic> changes) => {
            'id': 'a', 'type': 'text_choice', 'category': 'music', 'difficulty': 'hard',
            'question': {'text': 'Q?'}, 'correctAnswer': 'A',
            'incorrectAnswers': ['B', 'C', 'D'], ...changes};
      final questions = (await opened()).parseRandom([
        item({}),
        item({'type': 'image_choice'}),
        item({'type': 'text_input'}),
        item({'id': 7}),
        item({'question': 'Q?'}),
        item({'correctAnswer': ' '}),
        item({'incorrectAnswers': ['A', 'B', 'C']}),
        item({'incorrectAnswers': ['B', null]}),
        'not a question',
      ], base);
      expect(questions.map((q) => q.key), ['a']);
      expect(() => TheTriviaApiDialect().parseRandom({'questions': []}, base),
          throwsA(isA<FormatException>()));
    });

    test('credits The Trivia API, filters and doesn\'t report', () {
      final dialect = TheTriviaApiDialect();
      expect(dialect.attribution, contains('CC BY-NC 4.0'));
      expect(dialect.supportedFilters, {FilterKind.category, FilterKind.difficulty});
      expect(dialect.filtersOnServer, isTrue);
      expect(dialect.supportsReport, isFalse);
      expect(apiDialects['thetriviaapi']!(), isA<TheTriviaApiDialect>());
    });
  });

  group('HttpQuestionSource with The Trivia API', () {
    late List<Uri> requests;
    late List<Duration> waits;

    HttpQuestionSource sourceWith(FutureOr<http.Response> Function(Uri) handler) {
      requests = [];
      waits = [];
      var now = DateTime(2026, 10, 10);
      return HttpQuestionSource(
        baseUrl: base,
        dialect: TheTriviaApiDialect(),
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

    test('opens with the categories, then filters on the server', () async {
      final source = sourceWith((uri) => uri.path == '/v2/categories'
          ? fixtureResponse('categories.json')
          : fixtureResponse(uri.queryParameters.containsKey('categories')
              ? 'questions_filtered.json' : 'questions.json'));
      await source.open();
      expect(await source.filterCategories(), contains('Society & Culture'));
      expect((await source.randomQuestion()).category, isNot(contains('_')));
      const filter = QuestionFilter(categories: {'Geography', 'Music'}, difficulties: {'hard'});
      final q = await source.randomQuestion(filter: filter);
      expect(filter.matches(q), isTrue);
      expect(requests.map((u) => u.path), ['/v2/categories', '/v2/questions', '/v2/questions']);
      expect(requests.last.queryParameters['categories'], 'geography,music');
      expect(source.attribution, contains('The Trivia API'));
    });

    test('a page of the wrong category finds nothing rather than serving it', () async {
      final source = sourceWith((uri) => uri.path == '/v2/categories'
          ? fixtureResponse('categories.json')
          : fixtureResponse('questions_unknown_category.json'));
      await source.open();
      await expectLater(source.randomQuestion(
          filter: const QuestionFilter(categories: {'History'})),
          throwsA(isA<NoQuestionFound>()));
    });

    test('a rejected request is SourceUnavailable', () async {
      final source = sourceWith((uri) => uri.path == '/v2/categories'
          ? fixtureResponse('categories.json')
          : fixtureResponse('bad_difficulty.txt'));
      await source.open();
      await expectLater(source.randomQuestion(), throwsA(isA<SourceUnavailable>()
          .having((e) => e.message, 'message', contains('HTTP 400'))));
    });

    test('a failed category request fails open', () async {
      final source = sourceWith((_) => http.Response('', 503));
      await expectLater(source.open(), throwsA(isA<SourceUnavailable>()));
    });
  });
}
