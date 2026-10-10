import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';

/// The URLs and JSON shape of one kind of question API.
abstract class ApiDialect {
  /// Short name used in config, e.g. `jservice`.
  String get name;

  /// Whether [randomUri] applies the filter on the server.
  bool get filtersOnServer => false;

  /// The filters an [HttpQuestionSource] using this dialect applies reliably.
  Set<FilterKind> get supportedFilters => const {};

  Uri randomUri(Uri base, int count, QuestionFilter filter);

  /// Parses a random-questions response. Items that don't parse are skipped;
  /// a response that isn't the expected shape at all throws [FormatException].
  List<Question> parseRandom(Object? json, Uri base);

  bool get supportsReport => false;

  /// The URL to POST a report to. Only called when [supportsReport] is true.
  Uri reportUri(Uri base, Question question) =>
      throw UnsupportedError('$name has no reporting');

  /// Resolves [path] below [base], keeping any path prefix the base has
  /// (`https://host/quiz` + `api/random` -> `https://host/quiz/api/random`).
  static Uri endpoint(Uri base, String path, [Map<String, String>? query]) {
    final prefix = base.path.endsWith('/') ? base : base.replace(path: '${base.path}/');
    return prefix.resolve(path).replace(queryParameters: query);
  }
}

/// The dialects `QUESTION_API_DIALECT` can name.
final Map<String, ApiDialect Function()> apiDialects = {
  'quizapp': QuizApiDialect.new,
  'jservice': JServiceDialect.new,
};

/// This app's own API (v1), described in docs/question-backend-plan.md and
/// served by tool/serve_clues.py. Its fields are the clue database's columns.
class QuizApiDialect extends ApiDialect {
  static const maxCount = 50;

  @override
  String get name => 'quizapp';

  @override
  bool get filtersOnServer => true;

  /// Servers older than the `row` parameter ignore it, but [HttpQuestionSource]
  /// still checks [QuestionFilter.matches], so the filter holds; it just
  /// takes more batches.
  @override
  Set<FilterKind> get supportedFilters =>
      const {FilterKind.round, FilterKind.airDate, FilterKind.boardRow};

  @override
  Uri randomUri(Uri base, int count, QuestionFilter filter) {
    final rounds = filter.rounds;
    final boardRows = filter.boardRows;
    return ApiDialect.endpoint(base, 'v1/random', {
      'count': count.clamp(1, maxCount).toString(),
      if (rounds != null) 'round': (rounds.toList()..sort()).join(','),
      if (filter.from != null) 'from': isoDate(filter.from!),
      if (filter.to != null) 'to': isoDate(filter.to!),
      if (boardRows != null) 'row': (boardRows.toList()..sort()).join(','),
    });
  }

  @override
  List<Question> parseRandom(Object? json, Uri base) {
    const shapeError = FormatException('Expected an object with a "questions" list');
    if (json is! Map<String, dynamic>) throw shapeError;
    final questions = json['questions'];
    if (questions is! List) throw shapeError;
    final namespace = json['namespace'];
    final sourceId = namespace is String && namespace.isNotEmpty
        ? namespace
        : 'quizapp:${base.host}';
    final parsed = <Question>[];
    for (final item in questions) {
      final question = _parse(item, sourceId);
      if (question != null) parsed.add(question);
    }
    return parsed;
  }

  static Question? _parse(Object? item, String sourceId) {
    if (item is! Map<String, dynamic>) return null;
    final key = item['key'];
    final clue = item['clue'];
    final response = item['response'];
    final category = item['category'];
    if ((key is! String && key is! int) || clue is! String || response is! String ||
        category is! String) {
      return null;
    }
    final clueText = Question.sanitize(clue).trim();
    final responseText = Question.sanitize(response).trim();
    if ('$key'.isEmpty || clueText.isEmpty || responseText.isEmpty) return null;
    final choices = _choices(item['choices']);
    // Choices that can't be offered would make an unanswerable question.
    if (item['choices'] != null &&
        (choices == null || !Question.validChoices(choices, responseText))) {
      return null;
    }
    final round = _int(item['round']);
    final value = _int(item['value']);
    final wager = _int(item['dd_wager']);
    final airDate = item['air_date'];
    return Question(
      sourceId: sourceId,
      key: '$key',
      question: clueText,
      answer: responseText,
      category: Question.sanitize(category).trim(),
      // Final Jeopardy clues have value 0.
      value: round == 3 ? null : value,
      round: round,
      airDate: airDate is String ? DateTime.tryParse(airDate) : null,
      dailyDoubleWager: wager == 0 ? null : wager,
      categoryComment: _text(item['category_comment']),
      notes: _text(item['notes']),
      choices: choices,
      difficulty: _text(item['difficulty'])?.toLowerCase(),
      raw: item,
    );
  }

  /// The choices as sent, cleaned like the response; null unless every one
  /// is non-empty text.
  static List<String>? _choices(Object? value) {
    if (value is! List) return null;
    final choices = <String>[];
    for (final choice in value) {
      if (choice is! String) return null;
      final text = Question.sanitize(choice).trim();
      if (text.isEmpty) return null;
      choices.add(text);
    }
    return choices;
  }

  static int? _int(Object? value) => value is int ? value : null;

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  @override
  bool get supportsReport => true;

  @override
  Uri reportUri(Uri base, Question question) =>
      ApiDialect.endpoint(base, 'v1/questions/${Uri.encodeComponent(question.key)}/report');
}

/// The original jService API (`/api/random`, `/api/invalid`), as served by
/// self-hosted copies of jService and clones that kept its routes.
///
/// It supports no filters: its clues have no round, and filtering dates on
/// the client gives up after a few batches, so a narrow range fails.
class JServiceDialect extends ApiDialect {
  static const maxCount = 100;

  @override
  String get name => 'jservice';

  @override
  Uri randomUri(Uri base, int count, QuestionFilter filter) =>
      ApiDialect.endpoint(base, 'api/random',
          {'count': count.clamp(1, maxCount).toString()});

  @override
  List<Question> parseRandom(Object? json, Uri base) {
    if (json is! List) {
      throw const FormatException('Expected a JSON list of clues');
    }
    final sourceId = 'jservice:${base.host}';
    final questions = <Question>[];
    for (final item in json) {
      final question = _parse(item, sourceId);
      if (question != null) questions.add(question);
    }
    return questions;
  }

  // Returns null for malformed clues and for clues jService users have
  // flagged as invalid.
  static Question? _parse(Object? item, String sourceId) {
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
    final clue = Question.sanitize(question).trim();
    final response = Question.sanitize(answer).trim();
    if (clue.isEmpty || response.isEmpty) return null;
    final value = item['value'];
    final airdate = item['airdate'];
    return Question(
      sourceId: sourceId,
      key: id.toString(),
      question: clue,
      answer: response,
      category: Question.sanitize(title).trim(),
      value: value is int ? value : null,
      airDate: airdate is String ? DateTime.tryParse(airdate) : null,
      raw: item,
    );
  }

  @override
  bool get supportsReport => true;

  @override
  Uri reportUri(Uri base, Question question) =>
      ApiDialect.endpoint(base, 'api/invalid', {'id': question.key});
}
