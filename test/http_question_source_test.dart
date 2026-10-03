import 'dart:async';
import 'dart:convert' show json;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quizapp/data/api_dialect.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/question_source.dart';

import 'support/jservice_fixture.dart';
import 'support/quizapp_fixture.dart';

/// A jService response with [count] valid clues, ids starting at [first].
String jServiceBatch(int count, {int first = 1}) => json.encode([
  for (var id = first; id < first + count; id++)
    {
      'id': id,
      'question': 'Clue $id',
      'answer': 'Response $id',
      'value': 200,
      'airdate': '2001-01-01T12:00:00.000Z',
      'invalid_count': null,
      'category': {'title': 'category $id'},
    }
]);

void main() {
  final base = Uri.parse('https://example.test');

  group('JServiceDialect', () {
    final dialect = JServiceDialect();

    test('builds the random and invalid URLs', () {
      expect(dialect.randomUri(base, 10, QuestionFilter.any).toString(),
          'https://example.test/api/random?count=10');
      expect(dialect.randomUri(base, 500, QuestionFilter.any).queryParameters['count'],
          '100');
    });

    test('keeps a path prefix in the base URL', () {
      final prefixed = Uri.parse('https://example.test/quiz');
      expect(dialect.randomUri(prefixed, 1, QuestionFilter.any).toString(),
          'https://example.test/quiz/api/random?count=1');
      final question = dialect.parseRandom(json.decode(jServiceRandomResponse), base).first;
      expect(dialect.reportUri(prefixed, question).toString(),
          'https://example.test/quiz/api/invalid?id=87622');
    });

    test('parses clues, skipping flagged and malformed ones', () {
      final questions = dialect.parseRandom(json.decode(jServiceRandomResponse), base);
      expect(questions, hasLength(1));
      final q = questions.single;
      expect(q.sourceId, 'jservice:example.test');
      expect(q.key, '87622');
      expect(q.question, 'This 1939 novel follows the Joad family to California');
      expect(q.answer, 'The Grapes of Wrath');
      expect(q.category, 'american novels');
      expect(q.value, 400);
      expect(q.round, isNull);
      expect(q.airDate, DateTime.utc(2009, 3, 26, 12));
      expect(q.raw['category_id'], 11653);
    });

    test('rejects a response that is not a list', () {
      expect(() => dialect.parseRandom({'error': 'nope'}, base),
          throwsA(isA<FormatException>()));
    });
  });

  group('QuizApiDialect', () {
    final dialect = QuizApiDialect();

    test('builds the random URL with server-side filters', () {
      expect(dialect.randomUri(base, 10, QuestionFilter.any).toString(),
          'https://example.test/v1/random?count=10');
      final filtered = dialect.randomUri(base, 500, QuestionFilter(
          rounds: {2, 1}, from: DateTime(2001, 2, 3), to: DateTime(2010, 12, 31)));
      expect(filtered.path, '/v1/random');
      expect(filtered.queryParameters, {
        'count': '50', 'round': '1,2', 'from': '2001-02-03', 'to': '2010-12-31'});
    });

    test('builds the report URL under the base path', () {
      final question = dialect.parseRandom(json.decode(quizApiRandomResponse), base).first;
      expect(dialect.reportUri(Uri.parse('https://example.test/quiz/'), question).toString(),
          'https://example.test/quiz/v1/questions/-4182736451234567/report');
    });

    test('parses clues, skipping malformed ones', () {
      final questions = dialect.parseRandom(json.decode(quizApiRandomResponse), base);
      expect(questions.map((q) => q.key), ['-4182736451234567', '77']);

      final dd = questions[0];
      expect(dd.sourceId, 'jwolle1');
      expect(dd.question, "It's the largest living land animal");
      expect(dd.answer, 'an elephant');
      expect(dd.category, 'POTPOURRI');
      expect(dd.categoryComment, '(Alex: Each one is a mammal.)');
      expect(dd.round, 2);
      expect(dd.value, 800);
      expect(dd.dailyDoubleWager, 1500);
      expect(dd.airDate, DateTime(1984, 9, 11));
      expect(dd.notes, isNull);

      final finalClue = questions[1];
      expect(finalClue.isFinalJeopardy, isTrue);
      expect(finalClue.value, isNull);
      expect(finalClue.dailyDoubleWager, isNull);
      expect(finalClue.categoryComment, isNull);
      expect(finalClue.notes, 'Tournament of Champions game 1.');
    });

    test('accepts integer keys and falls back to a host namespace', () {
      final questions = dialect.parseRandom({
        'questions': [
          {'key': 5, 'category': 'C', 'clue': 'Q', 'response': 'A'},
        ],
      }, base);
      expect(questions.single.key, '5');
      expect(questions.single.sourceId, 'quizapp:example.test');
    });

    test('rejects a response without a questions list', () {
      expect(() => dialect.parseRandom([], base), throwsA(isA<FormatException>()));
      expect(() => dialect.parseRandom({'questions': 3}, base),
          throwsA(isA<FormatException>()));
    });
  });

  group('HttpQuestionSource', () {
    late List<http.Request> requests;

    HttpQuestionSource sourceWith(FutureOr<http.Response> Function(http.Request) handler,
        {String? token, Duration timeout = const Duration(seconds: 8)}) {
      requests = [];
      return HttpQuestionSource(
        baseUrl: base,
        dialect: JServiceDialect(),
        token: token,
        timeout: timeout,
        client: MockClient((request) async {
          requests.add(request);
          return handler(request);
        }),
      );
    }

    test('serves a batch from one request', () async {
      final source = sourceWith((_) => http.Response(jServiceBatch(10), 200));
      final keys = [for (var i = 0; i < 6; i++) (await source.randomQuestion()).key];
      expect(keys, ['1', '2', '3', '4', '5', '6']);
      expect(requests, hasLength(1));
      expect(requests.single.url.queryParameters['count'],
          '${HttpQuestionSource.batchSize}');
    });

    test('refills in the background before the buffer runs out', () async {
      var first = 1;
      final source = sourceWith((_) {
        final body = jServiceBatch(10, first: first);
        first += 10;
        return http.Response(body, 200);
      });
      for (var i = 0; i < 7; i++) {
        await source.randomQuestion();
      }
      // Taking the 7th leaves 3 in the buffer, which starts a refill.
      await pumpEventQueue();
      expect(requests, hasLength(2));
      final keys = [for (var i = 0; i < 4; i++) (await source.randomQuestion()).key];
      expect(keys, ['8', '9', '10', '11']);
      expect(requests, hasLength(2));
    });

    test('sends the bearer token when one is set', () async {
      final source = sourceWith((_) => http.Response(jServiceBatch(10), 200),
          token: 'secret');
      await source.randomQuestion();
      expect(requests.single.headers['Authorization'], 'Bearer secret');

      final anonymous = sourceWith((_) => http.Response(jServiceBatch(10), 200));
      await anonymous.randomQuestion();
      expect(requests.single.headers.containsKey('Authorization'), isFalse);
    });

    test('a server error is SourceUnavailable', () async {
      final source = sourceWith((_) => http.Response('oops', 500));
      await expectLater(source.randomQuestion(), throwsA(isA<SourceUnavailable>()
          .having((e) => e.message, 'message', contains('HTTP 500'))));
    });

    test('malformed JSON is SourceUnavailable', () async {
      final source = sourceWith((_) => http.Response('<html>', 200));
      await expectLater(source.randomQuestion(), throwsA(isA<SourceUnavailable>()));
    });

    test('a network error is SourceUnavailable', () async {
      final source = sourceWith((_) => throw http.ClientException('no route'));
      await expectLater(source.randomQuestion(), throwsA(isA<SourceUnavailable>()
          .having((e) => e.message, 'message', contains('no route'))));
    });

    test('a slow server is SourceUnavailable', () async {
      final source = sourceWith(
          (_) => Future.delayed(const Duration(seconds: 1), () => http.Response('[]', 200)),
          timeout: const Duration(milliseconds: 10));
      await expectLater(source.randomQuestion(), throwsA(isA<SourceUnavailable>()
          .having((e) => e.message, 'message', contains('in time'))));
    });

    test('filters on the client when the server cannot', () async {
      final source = sourceWith((_) => http.Response(jServiceBatch(10), 200));
      // jService clues have no round, so no batch can ever match.
      await expectLater(source.randomQuestion(filter: const QuestionFilter(rounds: {1})),
          throwsA(isA<NoQuestionFound>()));
      expect(requests, hasLength(HttpQuestionSource.maxFetchesPerQuestion));

      final dated = await source.randomQuestion(
          filter: QuestionFilter(from: DateTime(2000), to: DateTime(2002)));
      expect(dated.key, '1');
    });

    test('a server-filtered empty batch is NoQuestionFound at once', () async {
      requests = [];
      final source = HttpQuestionSource(baseUrl: base, dialect: QuizApiDialect(),
          client: MockClient((request) async {
            requests.add(request);
            return http.Response('{"namespace": "jwolle1", "questions": []}', 200);
          }));
      await expectLater(source.randomQuestion(filter: const QuestionFilter(rounds: {3})),
          throwsA(isA<NoQuestionFound>()));
      expect(requests, hasLength(1));
      expect(requests.single.url.queryParameters['round'], '3');
    });

    test('does not wait on a refill fetched for another filter', () async {
      final refill = Completer<http.Response>();
      var calls = 0;
      final source = sourceWith((request) {
        calls++;
        // The second request is the background refill; hold it.
        if (calls == 2) return refill.future;
        return http.Response(jServiceBatch(10, first: calls * 100), 200);
      });
      for (var i = 0; i < 7; i++) {
        await source.randomQuestion();
      }
      await pumpEventQueue();
      expect(calls, 2);
      // A new filter clears the buffer and fetches at once, without waiting
      // for the held refill.
      final dated = await source.randomQuestion(filter: QuestionFilter(from: DateTime(2000)));
      expect(dated.key, '300');
      refill.complete(http.Response(jServiceBatch(10, first: 900), 200));
      await pumpEventQueue();
      // The late refill was for the old filter, so it was dropped.
      expect((await source.randomQuestion(filter: QuestionFilter(from: DateTime(2000)))).key,
          '301');
    });

    test('reports by POSTing to the dialect report URL', () async {
      final source = sourceWith((_) => http.Response(jServiceBatch(10), 200));
      expect(source.supportsRemoteReport, isTrue);
      final question = await source.randomQuestion();
      await source.reportRemote(question);
      expect(requests.last.method, 'POST');
      expect(requests.last.url.toString(), 'https://example.test/api/invalid?id=1');
    });

    test('a failed report is SourceUnavailable', () async {
      final source = sourceWith((r) => r.method == 'POST'
          ? http.Response('', 503)
          : http.Response(jServiceBatch(10), 200));
      final question = await source.randomQuestion();
      await expectLater(source.reportRemote(question), throwsA(isA<SourceUnavailable>()));
    });
  });
}
