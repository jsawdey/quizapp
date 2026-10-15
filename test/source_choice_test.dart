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

  group('the configured server\'s databases', () {
    final nas = Uri.parse('http://nas:8080/');
    ServerDataset clues([Uri? at]) =>
        ServerDataset(name: 'clues', kind: 'clues', count: 6, url: at ?? nas);
    ServerDataset trivia([Uri? at]) => ServerDataset(name: 'trivia', kind: 'trivia', count: 61,
        url: at ?? nas.resolve('trivia/'));

    late InMemoryServerDatasetStore saved;
    setUp(() => saved = InMemoryServerDatasetStore());

    SourceChooser chooserFor(SourceConfig config, {ApiCredentials? credentials,
        String? pageHost, String? currentId, List<ServerDataset> datasets = const []}) =>
        SourceChooser(
            SourceChooser.buildOptions(config: config, credentials: credentials,
                bundledDatasets: both, pageHost: pageHost),
            store: InMemorySourceChoiceStore(),
            currentId: currentId,
            server: SourceChooser.configuredServer(config, credentials: credentials,
                pageHost: pageHost, store: saved),
            datasets: datasets);

    final api = SourceConfig.parse(source: 'api', apiUrl: 'http://nas:8080',
        apiDialect: 'quizapp', apiToken: 'secret', allowHttp: true);

    test('are offered after the configured one once learned', () {
      final chooser = chooserFor(api);
      expect(ids(chooser.options),
          ['configured', 'local:clues', 'local:trivia', 'opentdb', 'thetriviaapi']);
      expect(chooser.options.first.label, 'nas');

      expect(chooser.learn([clues(), trivia()]), isTrue);
      expect(ids(chooser.options), ['configured', 'server:trivia', 'local:clues',
        'local:trivia', 'opentdb', 'thetriviaapi']);
      // The configured URL is the default database, so it takes its name.
      expect(chooser.options.first.label, 'Jeopardy! clues');
      expect(chooser.options.first.detail, 'Your question server (nas)');
      expect(chooser.options[1].label, 'Trivia');
      expect(chooser.options[1].detail, 'Your question server (nas)');
      expect(chooser.options[1].create(), isA<HttpQuestionSource>()
          .having((s) => s.baseUrl, 'baseUrl', Uri.parse('http://nas:8080/trivia/'))
          .having((s) => s.dialect, 'dialect', isA<QuizApiDialect>())
          .having((s) => s.token, 'token', 'secret'));

      // The same list again changes nothing; an empty one comes from a
      // source that lists none.
      expect(chooser.learn([clues(), trivia()]), isFalse);
      expect(chooser.learn(const []), isFalse);
      expect(chooser.datasets, [clues(), trivia()]);
    });

    test('a build for one database finds the default on the server', () {
      final config = SourceConfig.parse(source: 'api', apiUrl: 'http://nas:8080/trivia',
          apiDialect: 'quizapp', allowHttp: true);
      final chooser = chooserFor(config);
      chooser.learn([clues(), trivia()]);
      expect(ids(chooser.options).take(2), ['configured', 'server:clues']);
      expect(chooser.options.first.label, 'Trivia');
      expect((chooser.options[1].create() as HttpQuestionSource).baseUrl, nas);
    });

    test('two of a kind are told apart by name', () {
      final chooser = chooserFor(api);
      chooser.learn([clues(), trivia(),
        ServerDataset(name: 'movies', kind: 'trivia', url: nas.resolve('movies/')),
        ServerDataset(name: 'quotes', kind: 'quotes', url: nas.resolve('quotes/'))]);
      expect([for (final o in chooser.options.take(4)) o.label],
          ['Jeopardy! clues', 'Trivia (trivia)', 'Trivia (movies)', 'quotes']);
    });

    test('nothing is learned from another server', () {
      final chooser = chooserFor(api);
      expect(chooser.learn([
        ServerDataset(name: 'trivia', kind: 'trivia', url: Uri.parse('https://evil.example/')),
        ServerDataset(name: 'x', kind: 'trivia', url: Uri.parse('http://nas:9090/x/')),
      ]), isFalse);
      expect(chooser.datasets, isEmpty);

      // Nor by a build that doesn't read from its own server.
      final local = chooserFor(SourceConfig.parse());
      expect(local.server, isNull);
      expect(local.learn([clues(), trivia()]), isFalse);
      final public = SourceConfig.parse(source: 'api', apiUrl: 'https://opentdb.com',
          apiDialect: 'opentdb');
      expect(SourceChooser.configuredServer(public, store: saved), isNull);
    });

    test('a token entered in the page reaches every database', () {
      final credentials = ApiCredentials();
      final web = SourceConfig.parse(isWeb: true, pageUrl: Uri.parse('http://nas:8080/'));
      final chooser = chooserFor(web, credentials: credentials, pageHost: 'nas');
      chooser.learn([clues(), trivia()]);
      expect(chooser.options.first.label, 'Jeopardy! clues');
      expect(chooser.options.first.detail, 'Your question server (nas)');
      final source = chooser.options[1].create() as HttpQuestionSource;
      expect(source.credentials, same(credentials));
    });

    test('a database falls back only to a bundled one of its kind', () {
      final config = SourceConfig.parse(source: 'api_with_local_fallback',
          apiUrl: 'http://nas:8080', apiDialect: 'quizapp', allowHttp: true);
      final chooser = chooserFor(config);
      chooser.learn([clues(), trivia(),
        ServerDataset(name: 'old', kind: 'clues', url: nas.resolve('old/'))]);
      expect(chooser.options.first.detail, 'Your question server (nas), or the clue '
          'database on this device while it is down');
      expect(chooser.options[1].id, 'server:trivia');
      expect(chooser.options[1].detail, 'Your question server (nas)');
      expect(chooser.options[1].create(), isA<HttpQuestionSource>());
      expect(chooser.options[2].create(), isA<FallbackQuestionSource>()
          .having((s) => s.fallback, 'fallback', isA<LocalQuestionSource>()
              .having((l) => l.dataset, 'dataset', LocalDataset.clues)));
    });

    test('are saved, so a saved choice of one survives a restart', () async {
      final chooser = chooserFor(api);
      chooser.learn([clues(), trivia()]);
      await pumpEventQueue();
      expect(saved.url, nas);
      expect(await saved.read(nas), [clues(), trivia()]);
      expect(await saved.read(Uri.parse('http://other:8080/')), isNull);

      final restarted = chooserFor(api, currentId: 'server:trivia',
          datasets: (await saved.read(nas))!);
      expect(restarted.current.id, 'server:trivia');
      // Without them, the saved choice can't be honoured yet.
      expect(chooserFor(api, currentId: 'server:trivia').current.id, 'configured');
    });

    test('the database in use stays listed until the next launch', () async {
      final chooser = chooserFor(api, datasets: [clues(), trivia()]);
      await chooser.choose('server:trivia');
      chooser.learn([clues()]);
      expect(ids(chooser.options).take(2), ['configured', 'server:trivia']);
      expect(chooser.current.id, 'server:trivia');
      expect(ids(chooserFor(api, datasets: [clues()]).options), isNot(contains('server:trivia')));
    });

    test('SharedPrefsServerDatasetStore keeps them for one server', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SharedPrefsServerDatasetStore();
      expect(await store.read(nas), isNull);
      await store.write(nas, [clues(), trivia()]);
      expect(await SharedPrefsServerDatasetStore().read(nas), [clues(), trivia()]);
      expect(await SharedPrefsServerDatasetStore().read(Uri.parse('http://pc:8080/')), isNull);
      SharedPreferences.setMockInitialValues({'server_datasets': 'not json'});
      expect(await SharedPrefsServerDatasetStore().read(nas), isNull);
    });
  });
}

class _BrokenStore implements SourceChoiceStore {
  @override
  Future<String?> read() async => throw StateError('broken');

  @override
  Future<void> write(String id) async => throw StateError('broken');
}
