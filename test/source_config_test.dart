import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/config/source_config.dart';
import 'package:quizapp/config/source_factory.dart';
import 'package:quizapp/data/api_dialect.dart';
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

    test('rejects an unknown source', () {
      expect(() => SourceConfig.parse(source: 'cloud'), configError('local, api'));
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

    test('an unavailable source reports why', () async {
      final source = UnavailableQuestionSource('bad settings');
      await expectLater(source.open(), throwsA(isA<SourceUnavailable>()
          .having((e) => e.message, 'message', 'bad settings')));
    });
  });
}
