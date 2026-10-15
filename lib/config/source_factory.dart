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

/// Reads [dataset], a database on the server [config] names, with the same
/// token. It falls back to the bundled database only when that holds the
/// same kind of question.
QuestionSource createServerDatasetSource(SourceConfig config, ServerDataset dataset,
    {ApiCredentials? credentials}) {
  final api = HttpQuestionSource(baseUrl: dataset.url, dialect: QuizApiDialect(),
      credentials: credentials ?? ApiCredentials(config.apiToken));
  if (config.kind == SourceKind.apiWithLocalFallback &&
      dataset.kind == config.localDataset.name) {
    return FallbackQuestionSource(primary: api,
        fallback: LocalQuestionSource(dataset: config.localDataset));
  }
  return api;
}

HttpQuestionSource _api(SourceConfig config, ApiCredentials? credentials) =>
    HttpQuestionSource(
      baseUrl: config.apiUrl!,
      dialect: apiDialects[config.apiDialect]!(),
      credentials: credentials ?? ApiCredentials(config.apiToken),
    );

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
