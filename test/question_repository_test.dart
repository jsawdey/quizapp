import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/controller/question_repository.dart';
import 'package:quizapp/data/filter_store.dart';
import 'package:quizapp/data/hidden_question_store.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/data/token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  group('switchSource', () {
    test('closes the old source and opens the new one, once', () async {
      final clues = FakeQuestionSource([fakeQuestion('c', sourceId: 'jwolle1')]);
      final trivia = FakeQuestionSource([fakeQuestion('t', sourceId: 'opentdb')]);
      final repository = repositoryWith(clues);
      expect((await repository.next()).key, 'c');
      await repository.switchSource(trivia);
      expect(clues.closes, 1);
      expect(repository.source, same(trivia));
      expect((await repository.next()).key, 't');
      await repository.next();
      expect(trivia.opens, 1);
      // Switching to the same source changes nothing.
      await repository.switchSource(trivia);
      expect(trivia.closes, 0);
    });

    test('keeps hidden questions and the filter, as far as the new source goes', () async {
      final clues = FakeQuestionSource([fakeQuestion('c')],
          supportedFilters: const {FilterKind.round});
      final trivia = FakeQuestionSource([fakeQuestion('t1'), fakeQuestion('t2')],
          supportedFilters: const {FilterKind.difficulty});
      final store = InMemoryFilterStore(
          const QuestionFilter(rounds: {3}, difficulties: {'hard'}));
      final repository = QuestionRepository(source: clues, hiddenStore: hidden,
          filterStore: store);
      await repository.next();
      expect(clues.lastFilter, const QuestionFilter(rounds: {3}));
      await repository.hide(fakeQuestion('t1'));

      await repository.switchSource(trivia);
      expect((await repository.next()).key, 't2');
      expect(trivia.lastFilter, const QuestionFilter(difficulties: {'hard'}));
    });

    test('a new source that fails to open is retried; the old one isn\'t', () async {
      final old = FakeQuestionSource([fakeQuestion('o')])
        ..openError = const SourceUnavailable('down');
      final fresh = FakeQuestionSource([fakeQuestion('n')])
        ..openError = const SourceUnavailable('no database');
      final repository = repositoryWith(old);
      await expectLater(repository.next(), throwsA(isA<SourceUnavailable>()));
      await repository.switchSource(fresh);
      await expectLater(repository.next(), throwsA(isA<SourceUnavailable>()));
      fresh.openError = null;
      expect((await repository.next()).key, 'n');
      expect(old.opens, 1);
    });
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

  group('access token', () {
    test('can only be set with a token store and credentials', () async {
      final repository = repositoryWith(FakeQuestionSource([fakeQuestion('1')]));
      expect(repository.canSetToken, isFalse);
      await expectLater(repository.setToken('x'), throwsStateError);
    });

    test('setToken saves the token and sends it from then on', () async {
      final credentials = ApiCredentials();
      final store = InMemoryTokenStore();
      final repository = QuestionRepository(
          source: TokenGuardedSource([fakeQuestion('1')],
              credentials: credentials, token: 's3cret'),
          hiddenStore: hidden, tokenStore: store, credentials: credentials);
      expect(repository.canSetToken, isTrue);
      await expectLater(repository.next(), throwsA(isA<Unauthorized>()));

      await repository.setToken(' s3cret ');
      expect(store.token, 's3cret');
      expect(credentials.token, 's3cret');
      expect((await repository.next()).key, '1');
    });

    test('a saved token is used when the repository opens', () async {
      final credentials = ApiCredentials();
      final repository = QuestionRepository(
          source: TokenGuardedSource([fakeQuestion('1')],
              credentials: credentials, token: 's3cret'),
          hiddenStore: hidden, tokenStore: InMemoryTokenStore('s3cret'),
          credentials: credentials);
      expect((await repository.next()).key, '1');
    });

    test('SharedPrefsTokenStore keeps the token', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SharedPrefsTokenStore();
      expect(await store.read(), isNull);
      await store.write('s3cret');
      expect(await SharedPrefsTokenStore().read(), 's3cret');
    });
  });

  group('filter', () {
    const both = {FilterKind.round, FilterKind.airDate};
    final nineties = QuestionFilter(from: DateTime(1990), to: DateTime(1999, 12, 31));

    QuestionRepository filtered(FakeQuestionSource source, FilterStore store) =>
        QuestionRepository(source: source, hiddenStore: hidden, filterStore: store);

    test('is any until one is chosen', () async {
      final source = FakeQuestionSource([fakeQuestion('1')], supportedFilters: both);
      final repository = filtered(source, InMemoryFilterStore());
      await repository.next();
      expect(repository.filter, QuestionFilter.any);
      expect(source.lastFilter, QuestionFilter.any);
    });

    test('setFilter saves it and uses it for the next question', () async {
      final source = FakeQuestionSource([fakeQuestion('1')], supportedFilters: both);
      final store = InMemoryFilterStore();
      final repository = filtered(source, store);
      await repository.setFilter(nineties);
      expect(store.filter, nineties);
      await repository.next();
      expect(source.lastFilter, nineties);
    });

    test('a saved filter is used once the repository opens', () async {
      final source = FakeQuestionSource([fakeQuestion('1')], supportedFilters: both);
      final repository = filtered(source, InMemoryFilterStore(nineties));
      await repository.next();
      expect(repository.filter, nineties);
      expect(source.lastFilter, nineties);
    });

    test('a filter chosen before opening wins over the saved one', () async {
      final source = FakeQuestionSource([fakeQuestion('1')], supportedFilters: both);
      final repository = filtered(source, InMemoryFilterStore(nineties));
      await repository.setFilter(const QuestionFilter(rounds: {3}));
      await repository.next();
      expect(source.lastFilter, const QuestionFilter(rounds: {3}));
    });

    test('drops what the source can\'t apply, and normalises', () async {
      final source = FakeQuestionSource([fakeQuestion('1')],
          supportedFilters: {FilterKind.airDate});
      final repository = filtered(source,
          InMemoryFilterStore(QuestionFilter(rounds: const {3}, from: DateTime(1990))));
      await repository.next();
      expect(source.lastFilter, QuestionFilter(from: DateTime(1990)));

      final both = FakeQuestionSource([fakeQuestion('1')],
          supportedFilters: const {FilterKind.round, FilterKind.airDate});
      final store = InMemoryFilterStore();
      await filtered(both, store).setFilter(const QuestionFilter(rounds: {1, 2, 3}));
      expect(store.filter, QuestionFilter.any);
    });

    test('applies only what the source supports now', () async {
      // A quizapp API says which filters it supports once it's open.
      final source = FakeQuestionSource([fakeQuestion('1')], supportedFilters: const {});
      const trivia = QuestionFilter(difficulties: {'hard'});
      final repository = filtered(source, InMemoryFilterStore(trivia));
      await repository.open();
      source.supportedFilters = const {FilterKind.difficulty};
      expect(repository.filter, trivia);
      await repository.next();
      expect(source.lastFilter, trivia);
      source.supportedFilters = const {};
      expect(repository.filter, QuestionFilter.any);
    });

    test('filterCategories opens the source and asks it', () async {
      final source = FakeQuestionSource([fakeQuestion('1')], categories: ['Art']);
      final repository = filtered(source, InMemoryFilterStore());
      expect(await repository.filterCategories(), ['Art']);
      expect(source.opens, 1);
    });

    test('an explicit filter overrides the chosen one', () async {
      final source = FakeQuestionSource([fakeQuestion('1')], supportedFilters: both);
      final repository = filtered(source, InMemoryFilterStore(nineties));
      await repository.next(filter: QuestionFilter.any);
      expect(source.lastFilter, QuestionFilter.any);
    });

    test('a filter that can\'t be read leaves questions unfiltered', () async {
      final source = FakeQuestionSource([fakeQuestion('1')], supportedFilters: both);
      final repository = filtered(source, _BrokenFilterStore());
      expect((await repository.next()).key, '1');
      expect(source.lastFilter, QuestionFilter.any);
    });
  });
}

class _BrokenFilterStore implements FilterStore {
  @override
  Future<QuestionFilter> read() async => throw StateError('storage is broken');

  @override
  Future<void> write(QuestionFilter filter) async => throw StateError('storage is broken');
}
