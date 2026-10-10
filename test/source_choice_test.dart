import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/config/source_choice.dart';
import 'package:quizapp/config/source_config.dart';
import 'package:quizapp/data/api_dialect.dart';
import 'package:quizapp/data/clue_database.dart';
import 'package:quizapp/data/fallback_question_source.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/local_question_source.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const both = {LocalDataset.clues, LocalDataset.trivia};

  List<String> ids(List<SourceOption> options) => [for (final o in options) o.id];

  group('buildOptions', () {
    test('a local build offers its database first, then the rest', () {
      final options = SourceChooser.buildOptions(
          config: SourceConfig.parse(), bundledDatasets: both);
      expect(ids(options), ['local:clues', 'local:trivia', 'opentdb', 'thetriviaapi']);
      expect(options.first.label, 'Jeopardy! clues');
      expect(options.first.create(), isA<LocalQuestionSource>()
          .having((s) => s.dataset, 'dataset', LocalDataset.clues));
      expect(options[1].create(), isA<LocalQuestionSource>()
          .having((s) => s.dataset, 'dataset', LocalDataset.trivia));
      expect(options[2].create(), isA<HttpQuestionSource>()
          .having((s) => s.dialect, 'dialect', isA<OpenTdbDialect>())
          .having((s) => s.baseUrl, 'baseUrl', Uri.parse('https://opentdb.com')));
      expect(options[3].create(), isA<HttpQuestionSource>()
          .having((s) => s.dialect, 'dialect', isA<TheTriviaApiDialect>()));
    });

    test('a trivia build lists trivia first; unbundled databases are left out', () {
      final options = SourceChooser.buildOptions(
          config: SourceConfig.parse(localDataset: 'trivia'),
          bundledDatasets: {LocalDataset.trivia});
      expect(ids(options), ['local:trivia', 'opentdb', 'thetriviaapi']);
    });

    test('a configured database that isn\'t bundled is still the default', () {
      // Choosing it says how to build it.
      final options = SourceChooser.buildOptions(config: SourceConfig.parse());
      expect(ids(options), ['local:clues', 'opentdb', 'thetriviaapi']);
    });

    test('a build for a public API lists it once', () {
      final options = SourceChooser.buildOptions(config: SourceConfig.parse(
          source: 'api', apiUrl: 'https://opentdb.com', apiDialect: 'opentdb'));
      expect(ids(options), ['opentdb', 'thetriviaapi']);
    });

    test('a build for its own server lists it first, and only it gets the token', () {
      final credentials = ApiCredentials('secret');
      final options = SourceChooser.buildOptions(
          config: SourceConfig.parse(source: 'api_with_local_fallback',
              apiUrl: 'https://quiz.example', apiDialect: 'quizapp'),
          credentials: credentials, bundledDatasets: both);
      expect(ids(options),
          ['configured', 'local:clues', 'local:trivia', 'opentdb', 'thetriviaapi']);
      expect(options.first.label, 'quiz.example');
      expect(options.first.detail, contains('clue database on this device'));
      final configured = options.first.create() as FallbackQuestionSource;
      expect((configured.primary as HttpQuestionSource).credentials, same(credentials));
      expect((options[3].create() as HttpQuestionSource).token, isNull);
    });

    test('a web build offers the page\'s server and the public APIs', () {
      final options = SourceChooser.buildOptions(
          config: SourceConfig.parse(isWeb: true, pageUrl: Uri.parse('http://pc.lan:8080/')),
          pageHost: 'pc.lan');
      expect(ids(options), ['configured', 'opentdb', 'thetriviaapi']);
      expect(options.first.label, 'This server');
      expect(options.first.detail, 'Your question server (pc.lan)');
    });

    test('broken settings become an option that explains itself', () async {
      final options = SourceChooser.buildOptions(configError: 'QUESTION_SOURCE is "x"');
      expect(ids(options), ['configured', 'opentdb', 'thetriviaapi']);
      await expectLater(options.first.create().open(), throwsA(isA<SourceUnavailable>()
          .having((e) => e.message, 'message', contains('QUESTION_SOURCE is "x"'))));
    });
  });

  group('SourceChooser', () {
    final options = SourceChooser.buildOptions(config: SourceConfig.parse(),
        bundledDatasets: both);

    test('starts with the saved choice, or the first option', () {
      final store = InMemorySourceChoiceStore();
      expect(SourceChooser(options, store: store).current.id, 'local:clues');
      expect(SourceChooser(options, store: store, currentId: 'opentdb').current.id, 'opentdb');
      // Saved by a build that offered more.
      expect(SourceChooser(options, store: store, currentId: 'configured').current.id,
          'local:clues');
      expect(SourceChooser(options, store: store).hasChoice, isTrue);
      expect(SourceChooser(options.take(1).toList(), store: store).hasChoice, isFalse);
    });

    test('choose saves the choice and makes its source', () async {
      final store = InMemorySourceChoiceStore();
      final chooser = SourceChooser(options, store: store);
      final source = await chooser.choose('local:trivia');
      expect(source, isA<LocalQuestionSource>()
          .having((s) => s.dataset, 'dataset', LocalDataset.trivia));
      expect(chooser.current.id, 'local:trivia');
      expect(store.id, 'local:trivia');
      expect(await chooser.choose('local:trivia'), isNull);
      expect(await chooser.choose('nonsense'), isNull);
      expect(chooser.current.id, 'local:trivia');
    });

    test('a failed save still switches', () async {
      final chooser = SourceChooser(options, store: _BrokenStore());
      expect(await chooser.choose('opentdb'), isNotNull);
      expect(chooser.current.id, 'opentdb');
    });

    test('SharedPrefsSourceChoiceStore keeps the choice', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await SharedPrefsSourceChoiceStore().read(), isNull);
      await SharedPrefsSourceChoiceStore().write('opentdb');
      expect(await SharedPrefsSourceChoiceStore().read(), 'opentdb');
    });
  });
}

class _BrokenStore implements SourceChoiceStore {
  @override
  Future<String?> read() async => throw StateError('broken');

  @override
  Future<void> write(String id) async => throw StateError('broken');
}
