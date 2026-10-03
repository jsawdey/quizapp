import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/controller/question_repository.dart';
import 'package:quizapp/data/hidden_question_store.dart';
import 'package:quizapp/data/question_source.dart';

import 'support/fakes.dart';

void main() {
  late InMemoryHiddenQuestionStore hidden;

  setUp(() => hidden = InMemoryHiddenQuestionStore());

  QuestionRepository repositoryWith(FakeQuestionSource source) =>
      QuestionRepository(source: source, hiddenStore: hidden);

  test('opens the source once', () async {
    final source = FakeQuestionSource([fakeQuestion('1')]);
    final repository = repositoryWith(source);
    await repository.next();
    await repository.next();
    expect(source.opens, 1);
  });

  test('a failed open is retried on the next call', () async {
    final source = FakeQuestionSource([fakeQuestion('1')])
      ..openError = const SourceUnavailable('no database');
    final repository = repositoryWith(source);
    await expectLater(repository.next(), throwsA(isA<SourceUnavailable>()));
    source.openError = null;
    expect((await repository.next()).key, '1');
    expect(source.opens, 2);
  });

  test('skips hidden questions', () async {
    final source = FakeQuestionSource([fakeQuestion('1'), fakeQuestion('2')]);
    final repository = repositoryWith(source);
    await repository.hide(fakeQuestion('1'));
    expect([for (var i = 0; i < 3; i++) (await repository.next()).key],
        ['2', '2', '2']);
  });

  test('hidden keys are per source', () async {
    final source = FakeQuestionSource([fakeQuestion('1', sourceId: 'other')]);
    final repository = repositoryWith(source);
    await repository.hide(fakeQuestion('1', sourceId: 'fake'));
    expect((await repository.next()).sourceId, 'other');
  });

  test('gives up after maxAttempts hidden questions', () async {
    final source = FakeQuestionSource([fakeQuestion('1')]);
    final repository = repositoryWith(source);
    await repository.hide(fakeQuestion('1'));
    await expectLater(repository.next(), throwsA(isA<NoQuestionFound>()));
  });

  test('passes source errors through', () async {
    final source = FakeQuestionSource([])..error = const SourceUnavailable('down');
    await expectLater(repositoryWith(source).next(), throwsA(isA<SourceUnavailable>()));
  });

  test('hide reports to sources that support it', () async {
    final source = FakeQuestionSource([], supportsRemoteReport: true);
    await repositoryWith(source).hide(fakeQuestion('7'));
    await pumpEventQueue();
    expect(source.reported.map((q) => q.key), ['7']);
  });

  test('hide does not report to sources that do not support it', () async {
    final source = FakeQuestionSource([]);
    await repositoryWith(source).hide(fakeQuestion('7'));
    await pumpEventQueue();
    expect(source.reported, isEmpty);
  });

  test('hide still works when the report fails', () async {
    final source = FakeQuestionSource([], supportsRemoteReport: true)
      ..reportError = const SourceUnavailable('offline');
    await repositoryWith(source).hide(fakeQuestion('7'));
    await pumpEventQueue();
    expect(hidden.isHidden(fakeQuestion('7')), isTrue);
  });
}
