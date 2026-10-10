import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/config/source_config.dart';
import 'package:quizapp/config/source_factory.dart';
import 'package:quizapp/data/api_dialect.dart';
import 'package:quizapp/data/fallback_question_source.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/local_question_source.dart';
import 'package:quizapp/data/question_source.dart';

Matcher configError(String text) =>
    throwsA(isA<SourceConfigError>().having((e) => e.message, 'message', contains(text)));

void main() {
  group('SourceConfig.parse', () {
    test('defaults to local', () {
      expect(SourceConfig.parse().kind, SourceKind.local);
      expect(SourceConfig.parse(source: 'local').kind, SourceKind.local);
      // API settings are ignored unless the source is api.
      expect(SourceConfig.parse(apiUrl: 'nonsense').kind, SourceKind.local);
    });

    test('the default build config is local', () {
      expect(SourceConfig.fromEnvironment().kind, SourceKind.local);
    });

    test('reads api settings', () {
      final config = SourceConfig.parse(source: 'api',
          apiUrl: ' https://clues.example/quiz ', apiDialect: 'jservice', apiToken: 't0k');
      expect(config.kind, SourceKind.api);
      expect(config.apiUrl, Uri.parse('https://clues.example/quiz'));
      expect(config.apiDialect, 'jservice');
      expect(config.apiToken, 't0k');
      expect(SourceConfig.parse(source: 'api', apiUrl: 'https://x.example',
          apiDialect: 'jservice').apiToken, isNull);
    });

    test('reads api_with_local_fallback', () {
      final config = SourceConfig.parse(source: 'api_with_local_fallback',
          apiUrl: 'https://x.example', apiDialect: 'quizapp');
      expect(config.kind, SourceKind.apiWithLocalFallback);
      expect(config.apiDialect, 'quizapp');
      expect(() => SourceConfig.parse(source: 'api_with_local_fallback'),
          configError('QUESTION_SOURCE is "api_with_local_fallback"'));
    });

    test('rejects an unknown source', () {
      expect(() => SourceConfig.parse(source: 'cloud'),
          configError('local, api, api_with_local_fallback'));
    });

    test('api needs a usable URL', () {
      for (final url in ['', 'clues.example', 'ftp://clues.example', 'https://']) {
        expect(() => SourceConfig.parse(source: 'api', apiUrl: url, apiDialect: 'jservice'),
            configError('QUESTION_API_URL'), reason: url);
      }
    });

    test('http is only allowed when allowHttp is set', () {
      expect(() => SourceConfig.parse(source: 'api', apiUrl: 'http://192.168.1.5:8080',
          apiDialect: 'jservice'), configError('https'));
      expect(SourceConfig.parse(source: 'api', apiUrl: 'http://192.168.1.5:8080',
          apiDialect: 'jservice', allowHttp: true).apiUrl!.port, 8080);
    });

    test('api needs a known dialect', () {
      expect(() => SourceConfig.parse(source: 'api', apiUrl: 'https://x.example'),
          configError('QUESTION_API_DIALECT'));
      expect(() => SourceConfig.parse(source: 'api', apiUrl: 'https://x.example',
          apiDialect: 'graphql'), configError(apiDialects.keys.join(', ')));
    });
  });

  group('SourceConfig.parse on the web', () {
    final page = Uri.parse('http://192.168.1.20:8080/index.html?x=1#top');

    SourceConfig web({String source = '', String apiUrl = '', String apiDialect = '',
        String apiToken = '', bool allowHttp = false}) => SourceConfig.parse(
        source: source, apiUrl: apiUrl, apiDialect: apiDialect, apiToken: apiToken,
        allowHttp: allowHttp, isWeb: true, pageUrl: page);

    test('defaults to the quizapp API on the page\'s origin', () {
      final config = web();
      expect(config.kind, SourceKind.api);
      expect(config.apiUrl, Uri.parse('http://192.168.1.20:8080/'));
      expect(config.apiDialect, 'quizapp');
      expect(config.apiToken, isNull);
    });

    test('keeps a default port out of the URL', () {
      expect(SourceConfig.parse(isWeb: true, pageUrl: Uri.parse('https://quiz.example/'))
          .apiUrl, Uri.parse('https://quiz.example/'));
    });

    test('allows http in release builds', () {
      expect(web(allowHttp: false).apiUrl!.scheme, 'http');
      expect(web(apiUrl: 'http://other.example', allowHttp: false).apiUrl!.host,
          'other.example');
    });

    test('reads explicit settings', () {
      final config = web(source: 'api', apiUrl: 'https://clues.example',
          apiDialect: 'jservice');
      expect(config.apiUrl, Uri.parse('https://clues.example'));
      expect(config.apiDialect, 'jservice');
    });

    test('can read from Open Trivia Database', () {
      final config = web(apiUrl: 'https://opentdb.com', apiDialect: 'opentdb');
      expect(config.apiUrl, Uri.parse('https://opentdb.com'));
      expect(config.apiDialect, 'opentdb');
      expect(createQuestionSource(config), isA<HttpQuestionSource>()
          .having((s) => s.dialect, 'dialect', isA<OpenTdbDialect>())
          .having((s) => s.attribution, 'attribution', contains('Open Trivia Database')));
    });

    test('rejects the local database', () {
      expect(() => web(source: 'local'), configError('isn\'t available in the browser'));
      expect(() => web(source: 'api_with_local_fallback'),
          configError('isn\'t available in the browser'));
    });

    test('rejects a compiled-in token', () {
      expect(() => web(apiToken: 'secret'), configError('QUESTION_API_TOKEN'));
    });

    test('needs a page URL or an API URL', () {
      expect(() => SourceConfig.parse(isWeb: true), configError('QUESTION_API_URL'));
    });
  });

  group('createQuestionSource', () {
    test('local', () {
      expect(createQuestionSource(SourceConfig.local), isA<LocalQuestionSource>());
    });

    test('api', () {
      final source = createQuestionSource(SourceConfig.parse(source: 'api',
          apiUrl: 'https://x.example', apiDialect: 'jservice', apiToken: 'abc'));
      expect(source, isA<HttpQuestionSource>()
          .having((s) => s.dialect, 'dialect', isA<JServiceDialect>())
          .having((s) => s.baseUrl, 'baseUrl', Uri.parse('https://x.example'))
          .having((s) => s.token, 'token', 'abc'));
    });

    test('api with credentials sends whatever they hold', () {
      final credentials = ApiCredentials('from the page');
      final source = createQuestionSource(SourceConfig.parse(source: 'api',
          apiUrl: 'https://x.example', apiDialect: 'quizapp'), credentials: credentials);
      expect(source, isA<HttpQuestionSource>()
          .having((s) => s.credentials, 'credentials', same(credentials))
          .having((s) => s.token, 'token', 'from the page'));
    });

    test('api with local fallback', () {
      final source = createQuestionSource(SourceConfig.parse(
          source: 'api_with_local_fallback', apiUrl: 'https://x.example',
          apiDialect: 'quizapp'));
      expect(source, isA<FallbackQuestionSource>()
          .having((s) => s.primary, 'primary', isA<HttpQuestionSource>()
              .having((s) => s.dialect, 'dialect', isA<QuizApiDialect>()))
          .having((s) => s.fallback, 'fallback', isA<LocalQuestionSource>()));
    });

    test('an unavailable source reports why', () async {
      final source = UnavailableQuestionSource('bad settings');
      await expectLater(source.open(), throwsA(isA<SourceUnavailable>()
          .having((e) => e.message, 'message', 'bad settings')));
    });
  });
}
