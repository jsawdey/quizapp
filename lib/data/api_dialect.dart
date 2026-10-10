import 'dart:convert' show utf8;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';

/// Sends a GET to a URL and returns the decoded JSON, with the same timeout,
/// pacing and errors as an [HttpQuestionSource]'s own requests.
typedef ApiRequester = Future<Object?> Function(Uri uri);

/// An API answered with an HTTP status the source doesn't handle itself,
/// such as 404 or 500.
class UnexpectedStatus extends SourceUnavailable {
  final int statusCode;
  const UnexpectedStatus(super.message, this.statusCode);
}

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

  /// Gets what [randomUri] needs to apply [filter], such as how many
  /// questions it matches. Called before the first batch for each filter.
  Future<void> prepare(ApiRequester get, Uri base, QuestionFilter filter) async {}

  /// The category names [QuestionFilter.categories] can choose from; see
  /// [QuestionSource.filterCategories].
  Future<List<String>> filterCategories(ApiRequester get, Uri base) async => const [];

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
  /// A query value may be a list, sent as the parameter repeated.
  static Uri endpoint(Uri base, String path, [Map<String, Object>? query]) {
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
/// served by tool/serve_clues.py, from the clue database or the trivia one.
/// Its fields are the clue database's columns, plus `choices` and
/// `difficulty` for trivia.
///
/// [open] asks `/v1/info` what the server holds; servers older than it are
/// taken to serve clues.
class QuizApiDialect extends ApiDialect {
  static const maxCount = 50;

  /// What a clue server filters on: what servers without `/v1/info` serve.
  static const clueFilters = {FilterKind.round, FilterKind.airDate, FilterKind.boardRow};

  /// The filter names `/v1/info` uses.
  static const _filterNames = {
    'round': FilterKind.round,
    'air_date': FilterKind.airDate,
    'row': FilterKind.boardRow,
    'category': FilterKind.category,
    'difficulty': FilterKind.difficulty,
  };

  Set<FilterKind> _filters = clueFilters;
  List<String> _categories = const [];
  String? _attribution;

  @override
  String get name => 'quizapp';

  @override
  bool get filtersOnServer => true;

  /// Servers older than the `row` parameter ignore it, but [HttpQuestionSource]
  /// still checks [QuestionFilter.matches], so the filter holds; it just
  /// takes more batches.
  @override
  Set<FilterKind> get supportedFilters => _filters;

  @override
  String? get attribution => _attribution;

  @override
  Future<List<String>> filterCategories(ApiRequester get, Uri base) async => _categories;

  @override
  Future<void> open(ApiRequester get, Uri base) async {
    final Object? info;
    try {
      info = await get(ApiDialect.endpoint(base, 'v1/info'));
    } on UnexpectedStatus catch (e) {
      // A server from before /v1/info: it serves clues.
      if (e.statusCode == 404 || e.statusCode == 405) return;
      rethrow;
    }
    if (info is! Map<String, dynamic>) throw const FormatException('Expected /v1/info object');
    final filters = info['filters'];
    final categories = info['categories'];
    final attribution = info['attribution'];
    _filters = filters is List
        ? {for (final name in filters) ?_filterNames[name]}
        : clueFilters;
    _categories = categories is List ? categories.whereType<String>().toList() : const [];
    _attribution = attribution is String && attribution.isNotEmpty ? attribution : null;
  }

  @override
  Uri randomUri(Uri base, int count, QuestionFilter filter) {
    final rounds = filter.rounds;
    final boardRows = filter.boardRows;
    final categories = filter.categories;
    final difficulties = filter.difficulties;
    return ApiDialect.endpoint(base, 'v1/random', {
      'count': count.clamp(1, maxCount).toString(),
      if (rounds != null) 'round': (rounds.toList()..sort()).join(','),
      if (filter.from != null) 'from': isoDate(filter.from!),
      if (filter.to != null) 'to': isoDate(filter.to!),
      if (boardRows != null) 'row': (boardRows.toList()..sort()).join(','),
      // Repeated, since a name may hold a comma.
      if (categories != null) 'category': categories.toList()..sort(),
      if (difficulties != null) 'difficulty': (difficulties.toList()..sort()).join(','),
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
/// keeps it from repeating questions.
///
/// A request takes one category and one difficulty, and fails outright if it
/// asks for more questions than they hold. So for a filter with categories,
/// [prepare] counts each one's questions, and each batch draws from one
/// category and difficulty, picked in proportion to their size and asking
/// for no more than it has.
class OpenTdbDialect extends ApiDialect {
  static const maxCount = 50;
  static const sourceId = 'opentdb';

  final Random _random;

  /// The session token, once [open] has got one.
  String? token;

  /// Category ids by name, from `api_category.php`.
  Map<String, int>? _categoryIds;

  /// Questions per category id: by difficulty, and in all under `total`.
  final Map<int, Map<String, int>> _counts = {};

  OpenTdbDialect({Random? random}) : _random = random ?? Random();

  @override
  String get name => 'opentdb';

  @override
  int get batchSize => maxCount;

  /// The API asks for one request per IP every 5 seconds.
  @override
  Duration get minRequestInterval => const Duration(seconds: 5);

  @override
  String get attribution => 'Questions from Open Trivia Database (opentdb.com), CC BY-SA 4.0';

  @override
  bool get filtersOnServer => true;

  @override
  Set<FilterKind> get supportedFilters => const {FilterKind.category, FilterKind.difficulty};

  /// The names in alphabetical order, which keeps "Entertainment: …" together.
  @override
  Future<List<String>> filterCategories(ApiRequester get, Uri base) async =>
      (await _categories(get, base)).keys.toList()..sort();

  Future<Map<String, int>> _categories(ApiRequester get, Uri base) async {
    final known = _categoryIds;
    if (known != null) return known;
    final json = await get(ApiDialect.endpoint(base, 'api_category.php'));
    final list = json is Map<String, dynamic> ? json['trivia_categories'] : null;
    if (list is! List) throw const FormatException('Expected a "trivia_categories" list');
    return _categoryIds = {
      for (final item in list)
        if (item is Map<String, dynamic> && item['id'] is int && item['name'] is String)
          (item['name'] as String).trim(): item['id'] as int,
    };
  }

  /// Counts the questions in each chosen category, once per category.
  @override
  Future<void> prepare(ApiRequester get, Uri base, QuestionFilter filter) async {
    final categories = filter.categories;
    if (categories == null) return;
    final ids = await _categories(get, base);
    for (final name in categories) {
      final id = ids[name];
      if (id == null || _counts.containsKey(id)) continue;
      final json = await get(ApiDialect.endpoint(base, 'api_count.php', {'category': '$id'}));
      final counts = json is Map<String, dynamic> ? json['category_question_count'] : null;
      if (counts is! Map<String, dynamic>) {
        throw const FormatException('Expected a "category_question_count" object');
      }
      int count(String key) => counts[key] as int? ?? 0;
      _counts[id] = {
        'total': count('total_question_count'),
        for (final difficulty in QuestionFilter.allDifficulties)
          difficulty: count('total_${difficulty}_question_count'),
      };
    }
  }

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

  /// Throws [NoQuestionFound] if none of the filter's categories has
  /// questions of its difficulties.
  @override
  Uri randomUri(Uri base, int count, QuestionFilter filter) {
    var amount = count.clamp(1, maxCount);
    int? category;
    String? difficulty;
    final difficulties = filter.difficulties?.toList()?..sort();
    final categories = filter.categories;
    if (categories != null) {
      final pools = [
        for (final name in categories.toList()..sort())
          if (_categoryIds?[name] case final id? when _counts.containsKey(id))
            for (final level in difficulties ?? const [null])
              (id: id, difficulty: level, size: _counts[id]![level ?? 'total']!),
      ].where((pool) => pool.size > 0).toList();
      if (pools.isEmpty) {
        throw NoQuestionFound('${base.host} has no questions matching the filter.');
      }
      final pool = _pick(pools);
      category = pool.id;
      difficulty = pool.difficulty;
      amount = min(amount, pool.size);
    } else if (difficulties != null && difficulties.isNotEmpty) {
      // Every difficulty has well over a batch of questions.
      difficulty = difficulties[_random.nextInt(difficulties.length)];
    }
    return ApiDialect.endpoint(base, 'api.php', {
      'amount': '$amount',
      'category': ?category?.toString(),
      'difficulty': ?difficulty,
      'encode': 'url3986',
      'token': ?token,
    });
  }

  /// A pool picked in proportion to its size, so every question in the
  /// filter is about as likely.
  ({int id, String? difficulty, int size}) _pick(
      List<({int id, String? difficulty, int size})> pools) {
    var at = _random.nextInt(pools.fold(0, (sum, pool) => sum + pool.size));
    for (final pool in pools) {
      if (at < pool.size) return pool;
      at -= pool.size;
    }
    return pools.last;
  }

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
