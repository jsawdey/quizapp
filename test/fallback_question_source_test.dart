import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/data/fallback_question_source.dart';
import 'package:quizapp/data/question_source.dart';

import 'support/fakes.dart';

void main() {
  late FakeQuestionSource primary;
  late FakeQuestionSource fallback;
  late DateTime now;
  late FallbackQuestionSource source;

  setUp(() {
    primary = FakeQuestionSource([fakeQuestion('p', sourceId: 'api')],
        supportsRemoteReport: true);
    fallback = FakeQuestionSource([fakeQuestion('f', sourceId: 'local')]);
    now = DateTime(2026, 1, 1);
    source = FallbackQuestionSource(primary: primary, fallback: fallback,
        retryAfter: const Duration(seconds: 60), now: () => now);
  });

  test('uses the primary while it works, opening only what it needs', () async {
    await source.open();
    expect(primary.opens, 0);
    expect((await source.randomQuestion()).key, 'p');
    expect(source.usingFallback, isFalse);
    expect(primary.opens, 1);
    expect(fallback.opens, 0);
  });

  test('switches to the fallback when the primary is unavailable', () async {
    primary.error = const SourceUnavailable('offline');
    expect((await source.randomQuestion()).key, 'f');
    expect(source.usingFallback, isTrue);
  });

  test('a primary that fails to open falls back too', () async {
    primary.openError = const SourceUnavailable('no route');
    expect((await source.randomQuestion()).key, 'f');
    primary.openError = null;
    now = now.add(const Duration(seconds: 61));
    expect((await source.randomQuestion()).key, 'p');
    expect(primary.opens, 2);
  });

  test('retries the primary only after the cooldown', () async {
    primary.error = const SourceUnavailable('offline');
    await source.randomQuestion();
    primary.error = null;

    now = now.add(const Duration(seconds: 30));
    expect((await source.randomQuestion()).key, 'f');
    // Serving from the fallback doesn't restart the cooldown.
    now = now.add(const Duration(seconds: 31));
    expect((await source.randomQuestion()).key, 'p');
    expect(source.usingFallback, isFalse);
  });

  test('NoQuestionFound from the primary is passed on', () async {
    primary.error = const NoQuestionFound('none match');
    await expectLater(source.randomQuestion(), throwsA(isA<NoQuestionFound>()));
    expect(fallback.opens, 0);
  });

  test('both unavailable reports both reasons, keeping the first', () async {
    primary.error = const SourceUnavailable('API down');
    fallback.openError = const SourceUnavailable('no database');
    final matcher = throwsA(isA<SourceUnavailable>().having((e) => e.message, 'message',
        allOf(contains('API down'), contains('no database'))));
    await expectLater(source.randomQuestion(), matcher);
    // Still in the cooldown: the primary isn't asked, but its reason is kept.
    primary.error = const SourceUnavailable('another reason');
    await expectLater(source.randomQuestion(), matcher);
  });

  test('reports go to the source that served the question', () async {
    expect(source.supportsRemoteReport, isTrue);
    final fromPrimary = await source.randomQuestion();
    primary.error = const SourceUnavailable('offline');
    final fromFallback = await source.randomQuestion();

    await source.reportRemote(fromPrimary);
    await source.reportRemote(fromFallback);
    expect(primary.reported, [fromPrimary]);
    // The fallback doesn't support reports, so nothing is sent for its clue.
    expect(fallback.reported, isEmpty);
  });

  test('closes both sources', () async {
    await source.close();
    expect(primary.closes, 1);
    expect(fallback.closes, 1);
  });
}
