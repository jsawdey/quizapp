import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';

/// The URLs and JSON shape of one kind of question API.
abstract class ApiDialect {
  /// Short name used in config, e.g. `jservice`.
  String get name;

  /// Whether [randomUri] applies the filter on the server.
  bool get filtersOnServer => false;

  Uri randomUri(Uri base, int count, QuestionFilter filter);

  /// Parses a random-questions response. Items that don't parse are skipped;
  /// a response that isn't the expected shape at all throws [FormatException].
  List<JeopardyQuestion> parseRandom(Object? json, Uri base);

  bool get supportsReport => false;

  /// The URL to POST a report to. Only called when [supportsReport] is true.
  Uri reportUri(Uri base, JeopardyQuestion question) =>
      throw UnsupportedError('$name has no reporting');

  /// Resolves [path] below [base], keeping any path prefix the base has
  /// (`https://host/quiz` + `api/random` -> `https://host/quiz/api/random`).
  static Uri endpoint(Uri base, String path, [Map<String, String>? query]) {
    final prefix = base.path.endsWith('/') ? base : base.replace(path: '${base.path}/');
    return prefix.resolve(path).replace(queryParameters: query);
  }
}

/// The original jService API (`/api/random`, `/api/invalid`), as served by
/// self-hosted copies of jService and clones that kept its routes.
class JServiceDialect extends ApiDialect {
  static const maxCount = 100;

  @override
  String get name => 'jservice';

  @override
  Uri randomUri(Uri base, int count, QuestionFilter filter) =>
      ApiDialect.endpoint(base, 'api/random',
          {'count': count.clamp(1, maxCount).toString()});

  @override
  List<JeopardyQuestion> parseRandom(Object? json, Uri base) {
    if (json is! List) {
      throw const FormatException('Expected a JSON list of clues');
    }
    final sourceId = 'jservice:${base.host}';
    final questions = <JeopardyQuestion>[];
    for (final item in json) {
      final question = _parse(item, sourceId);
      if (question != null) questions.add(question);
    }
    return questions;
  }

  // Returns null for malformed clues and for clues jService users have
  // flagged as invalid.
  static JeopardyQuestion? _parse(Object? item, String sourceId) {
    if (item is! Map<String, dynamic>) return null;
    final id = item['id'];
    final question = item['question'];
    final answer = item['answer'];
    final category = item['category'];
    final title = category is Map ? category['title'] : null;
    if (id is! int || question is! String || answer is! String || title is! String) {
      return null;
    }
    final invalidCount = int.tryParse('${item['invalid_count'] ?? 0}') ?? 0;
    if (invalidCount != 0) return null;
    final clue = JeopardyQuestion.sanitize(question).trim();
    final response = JeopardyQuestion.sanitize(answer).trim();
    if (clue.isEmpty || response.isEmpty) return null;
    final value = item['value'];
    final airdate = item['airdate'];
    return JeopardyQuestion(
      sourceId: sourceId,
      key: id.toString(),
      question: clue,
      answer: response,
      category: JeopardyQuestion.sanitize(title).trim(),
      value: value is int ? value : null,
      airDate: airdate is String ? DateTime.tryParse(airdate) : null,
      raw: item,
    );
  }

  @override
  bool get supportsReport => true;

  @override
  Uri reportUri(Uri base, JeopardyQuestion question) =>
      ApiDialect.endpoint(base, 'api/invalid', {'id': question.key});
}
