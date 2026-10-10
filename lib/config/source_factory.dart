import 'package:quizapp/config/source_config.dart';
import 'package:quizapp/data/api_dialect.dart';
import 'package:quizapp/data/fallback_question_source.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/local_question_source.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';

/// Builds the question source described by [config]. An API source sends
/// the token in [credentials] if given, else the configured one.
QuestionSource createQuestionSource(SourceConfig config, {ApiCredentials? credentials}) {
  switch (config.kind) {
    case SourceKind.local:
      return LocalQuestionSource(dataset: config.localDataset);
    case SourceKind.api:
      return _api(config, credentials);
    case SourceKind.apiWithLocalFallback:
      return FallbackQuestionSource(primary: _api(config, credentials),
          fallback: LocalQuestionSource(dataset: config.localDataset));
  }
}

HttpQuestionSource _api(SourceConfig config, ApiCredentials? credentials) =>
    HttpQuestionSource(
      baseUrl: config.apiUrl!,
      dialect: apiDialects[config.apiDialect]!(),
      credentials: credentials ?? ApiCredentials(config.apiToken),
    );

/// Builds the source this build was configured with. A bad configuration
/// gives a source whose [QuestionSource.open] fails with the problem, so the
/// app reports it instead of crashing.
QuestionSource questionSourceFromEnvironment({ApiCredentials? credentials}) {
  try {
    return createQuestionSource(SourceConfig.fromEnvironment(), credentials: credentials);
  } on SourceConfigError catch (e) {
    return UnavailableQuestionSource('Invalid question source settings: ${e.message}');
  }
}

/// A source that can never be opened, carrying the reason why.
class UnavailableQuestionSource extends QuestionSource {
  final String reason;
  UnavailableQuestionSource(this.reason);

  @override
  String get description => 'no question source';

  @override
  Future<void> open() async => throw SourceUnavailable(reason);

  @override
  Future<Question> randomQuestion({QuestionFilter filter = QuestionFilter.any}) async =>
      throw SourceUnavailable(reason);
}
