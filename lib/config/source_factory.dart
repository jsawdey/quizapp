import 'package:quizapp/config/source_config.dart';
import 'package:quizapp/data/api_dialect.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/local_question_source.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';

/// Builds the question source described by [config].
QuestionSource createQuestionSource(SourceConfig config) {
  switch (config.kind) {
    case SourceKind.local:
      return LocalQuestionSource();
    case SourceKind.api:
      return HttpQuestionSource(
        baseUrl: config.apiUrl!,
        dialect: apiDialects[config.apiDialect]!(),
        token: config.apiToken,
      );
  }
}

/// Builds the source this build was configured with. A bad configuration
/// gives a source whose [QuestionSource.open] fails with the problem, so the
/// app reports it instead of crashing.
QuestionSource questionSourceFromEnvironment() {
  try {
    return createQuestionSource(SourceConfig.fromEnvironment());
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
  Future<JeopardyQuestion> randomQuestion({QuestionFilter filter = QuestionFilter.any}) async =>
      throw SourceUnavailable(reason);
}
