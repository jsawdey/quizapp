import 'dart:convert' show utf8;

import 'package:crypto/crypto.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';

/// Sends a GET to a URL and returns the decoded JSON, with the same timeout,
/// pacing and errors as an [HttpQuestionSource]'s own requests.
typedef ApiRequester = Future<Object?> Function(Uri uri);

/// Thrown by [ApiDialect.parseRandom] when the API's session has expired or
/// run out: the source calls [ApiDialect.open] again and retries once.
class SessionExpired implements Exception {
  final String message;
  const SessionExpired(this.message);

  @override
  String toString() => message;
}

/// The URLs and JSON shape of one kind of question API.
abstract class ApiDialect {
  /// Short name used in config, e.g. `jservice`.
  String get name;

  /// How many questions to ask for at a time, and how few may be left before
  /// the next batch is fetched in the background.
  int get batchSize => 10;
  int get refillAt => 3;

  /// The least time between batch requests, for APIs with a rate limit.
  Duration get minRequestInterval => Duration.zero;

  /// The credit the API's license asks for; see [QuestionSource.attribution].
  String? get attribution => null;

  /// Prepares a session, such as getting a token. Called when the source
  /// opens and after [SessionExpired]; may throw [SourceUnavailable] or
  /// [FormatException].
  Future<void> open(ApiRequester get, Uri base) async {}

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

  /// What to say when an API refuses requests for coming too fast.
  static String busyMessage(String host) => '$host is busy; try again in a few seconds.';

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
  'opentdb': OpenTdbDialect.new,
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

/// Open Trivia Database (opentdb.com): general trivia, multiple choice and
/// true/false, CC BY-SA 4.0. Checked against the live API; see
/// docs/general-trivia-plan.md §4 and test/support/opentdb/.
///
/// Its questions have no ids, so keys hash the text, and a session token
/// keeps it from repeating questions. It supports no filters yet.
class OpenTdbDialect extends ApiDialect {
  static const maxCount = 50;
  static const sourceId = 'opentdb';

  /// The session token, once [open] has got one.
  String? token;

  @override
  String get name => 'opentdb';

  @override
  int get batchSize => maxCount;

  /// The API asks for one request per IP every 5 seconds.
  @override
  Duration get minRequestInterval => const Duration(seconds: 5);

  @override
  String get attribution => 'Questions from Open Trivia Database (opentdb.com), CC BY-SA 4.0';

  /// Gets a new token. A new token has seen nothing, so it also serves after
  /// an old one has run out of questions.
  @override
  Future<void> open(ApiRequester get, Uri base) async {
    final json = await get(ApiDialect.endpoint(base, 'api_token.php', {'command': 'request'}));
    final token = json is Map<String, dynamic> && json['response_code'] == 0
        ? json['token']
        : null;
    if (token is! String || token.isEmpty) {
      throw const FormatException('Expected a session token');
    }
    this.token = token;
  }

  @override
  Uri randomUri(Uri base, int count, QuestionFilter filter) =>
      ApiDialect.endpoint(base, 'api.php', {
        'amount': count.clamp(1, maxCount).toString(),
        'encode': 'url3986',
        'token': ?token,
      });

  @override
  List<Question> parseRandom(Object? json, Uri base) {
    const shapeError = FormatException('Expected an object with a response_code');
    if (json is! Map<String, dynamic>) throw shapeError;
    final code = json['response_code'];
    switch (code) {
      case 0:
        final results = json['results'];
        if (results is! List) throw const FormatException('Expected a "results" list');
        return [for (final item in results) ?_parse(item)];
      // Asking for more than match: there is no short page.
      case 1:
        throw NoQuestionFound('${base.host} has no questions matching the request.');
      case 2:
        throw SourceUnavailable('${base.host} rejected the request as invalid.');
      case 3:
        throw const SessionExpired('The session token was not found.');
      // Also sent when fewer unseen questions are left than were asked for.
      case 4:
        throw const SessionExpired('The session token has run out of questions.');
      // Usually HTTP 429, which HttpQuestionSource reports first.
      case 5:
        throw SourceUnavailable(ApiDialect.busyMessage(base.host));
      default:
        throw shapeError;
    }
  }

  /// Returns null for items that don't parse, or whose choices can't be
  /// offered.
  static Question? _parse(Object? item) {
    if (item is! Map<String, dynamic>) return null;
    final type = item['type'];
    final question = _decode(item['question']);
    final answer = _decode(item['correct_answer']);
    final category = _decode(item['category']);
    final incorrect = item['incorrect_answers'];
    if (question == null || answer == null || category == null || incorrect is! List) {
      return null;
    }
    final others = [for (final choice in incorrect) _decode(choice)];
    if (others.contains(null)) return null;
    final key = questionKey(category, question, answer);
    final List<String> choices;
    if (type == 'boolean') {
      choices = const ['True', 'False'];
    } else if (type == 'multiple') {
      choices = stableShuffle(key, [answer, ...others.cast<String>()]);
    } else {
      return null;
    }
    if (!Question.validChoices(choices, answer)) return null;
    final difficulty = item['difficulty'];
    return Question(
      sourceId: sourceId,
      key: key,
      question: question,
      answer: answer,
      category: category,
      choices: choices,
      difficulty: difficulty is String && difficulty.isNotEmpty
          ? difficulty.toLowerCase()
          : null,
      raw: {
        ...item,
        'question': question,
        'correct_answer': answer,
        'incorrect_answers': others,
        'category': category,
      },
    );
  }

  /// Decodes a `url3986` text field and trims it: some answers come with a
  /// stray space. Null if it isn't text or isn't valid encoding.
  static String? _decode(Object? value) {
    if (value is! String) return null;
    try {
      final text = Uri.decodeComponent(value).trim();
      return text.isEmpty ? null : text;
    } on ArgumentError {
      return null;
    }
  }

  /// The first 16 hex characters of the SHA-256 of the category, question
  /// and answer, NUL-separated: OpenTDB questions have no ids. An edited
  /// question gets a new key, so hiding it doesn't carry over.
  static String questionKey(String category, String question, String answer) =>
      _sha256('$category\u0000$question\u0000$answer').substring(0, 16);

  /// [choices] in an order that looks random but is the same everywhere for
  /// [key]: each choice is ranked by the hash of the key and the choice.
  static List<String> stableShuffle(String key, List<String> choices) {
    final ranks = {for (final choice in choices) choice: _sha256('$key\u0000$choice')};
    return [...choices]..sort((a, b) => ranks[a]!.compareTo(ranks[b]!));
  }

  static String _sha256(String text) => sha256.convert(utf8.encode(text)).toString();
}
