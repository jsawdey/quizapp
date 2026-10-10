import 'dart:async';
import 'dart:collection';
import 'dart:convert' show json;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:quizapp/data/api_dialect.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';

/// The bearer token an [HttpQuestionSource] sends. Separate from the source so
/// the token can change while the app runs: the web UI asks for it.
class ApiCredentials {
  String? token;
  ApiCredentials([this.token]);
}

/// Fetches questions from an HTTP API in batches and serves them from a
/// buffer, refilling it in the background before it runs out. The dialect
/// sets the batch size, the pace and any session.
class HttpQuestionSource extends QuestionSource {
  /// Batches to try before giving up on a filter the server can't apply.
  static const maxFetchesPerQuestion = 3;

  final Uri baseUrl;
  final ApiDialect dialect;
  final ApiCredentials credentials;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;

  final Queue<Question> _buffer = Queue();
  QuestionFilter _bufferFilter = QuestionFilter.any;
  Future<void>? _refill;
  QuestionFilter? _refillFilter;
  Future<void>? _session;
  /// The filter [ApiDialect.prepare] last ran for.
  QuestionFilter? _preparedFor;
  /// When the next batch may be requested, under [ApiDialect.minRequestInterval].
  DateTime? _nextBatchAt;

  /// Sends [token], or whatever [credentials] holds when the request is made.
  /// [now] and [delay] stand in for the clock in tests.
  HttpQuestionSource({required this.baseUrl, required this.dialect, String? token,
    ApiCredentials? credentials, this.timeout = const Duration(seconds: 8),
    http.Client? client, DateTime Function()? now,
    Future<void> Function(Duration)? delay})
      : credentials = credentials ?? ApiCredentials(token),
        _client = client ?? http.Client(),
        _ownsClient = client == null,
        _now = now ?? DateTime.now,
        _delay = delay ?? Future<void>.delayed;

  String? get token => credentials.token;

  @override
  String get description => baseUrl.host;

  @override
  bool get supportsRemoteReport => dialect.supportsReport;

  @override
  Set<FilterKind> get supportedFilters => dialect.supportedFilters;

  @override
  String? get attribution => dialect.attribution;

  /// Starts the dialect's session, if it has one.
  @override
  Future<void> open() => _startSession();

  /// Runs [ApiDialect.open], joining a run already in progress.
  Future<void> _startSession() =>
      _session ??= _openDialect().whenComplete(() => _session = null);

  Future<void> _openDialect() => _unexpectedAsUnavailable(() => dialect.open(_getJson, baseUrl));

  @override
  Future<List<String>> filterCategories() =>
      _unexpectedAsUnavailable(() => dialect.filterCategories(_getJson, baseUrl));

  /// Runs [action], turning a [FormatException] into [SourceUnavailable].
  Future<T> _unexpectedAsUnavailable<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on FormatException catch (e) {
      throw SourceUnavailable('$description sent an unexpected response: ${e.message}');
    }
  }

  Future<Object?> _getJson(Uri uri) async =>
      json.decode(await _send(() => _client.get(uri, headers: _headers)));

  Map<String, String> get _headers {
    final token = this.token;
    return {
      'Accept': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  @override
  Future<Question> randomQuestion({QuestionFilter filter = QuestionFilter.any}) async {
    if (filter != _bufferFilter) {
      _buffer.clear();
      _bufferFilter = filter;
    }
    for (var fetches = 0; ; fetches++) {
      while (_buffer.isNotEmpty) {
        final question = _buffer.removeFirst();
        if (filter.matches(question)) {
          if (_buffer.length <= dialect.refillAt) _refillInBackground(filter);
          return question;
        }
      }
      if (fetches == maxFetchesPerQuestion) {
        throw NoQuestionFound('$description returned no question matching the filter.');
      }
      final refill = _refill;
      if (refill != null && _refillFilter == filter) {
        await refill;
      } else if (await _fetchBatch(filter) == 0 && dialect.filtersOnServer) {
        // The server applied the filter and found nothing.
        throw NoQuestionFound('$description has no question matching the filter.');
      }
    }
  }

  void _refillInBackground(QuestionFilter filter) {
    if (_refill != null) return;
    _refillFilter = filter;
    _refill = _fetchBatch(filter).then<void>((_) {}, onError: (Object error) {
      // The next randomQuestion call fetches again and reports the error.
      debugPrint('Background refill from $description failed: $error');
    }).whenComplete(() => _refill = null);
  }

  /// Fetches one batch into the buffer and returns how many questions it
  /// added. An expired session is started again once.
  Future<int> _fetchBatch(QuestionFilter filter) async {
    List<Question> questions;
    try {
      questions = await _requestBatch(filter);
    } on SessionExpired catch (e) {
      debugPrint('$description: $e Starting a new session.');
      await _startSession();
      try {
        questions = await _requestBatch(filter);
      } on SessionExpired catch (e) {
        throw SourceUnavailable('$description keeps refusing its session: ${e.message}');
      }
    }
    // Drop the batch if the filter changed while it was in flight.
    if (filter != _bufferFilter) return 0;
    _buffer.addAll(questions);
    return questions.length;
  }

  Future<List<Question>> _requestBatch(QuestionFilter filter) async {
    if (_preparedFor != filter) {
      await _unexpectedAsUnavailable(() => dialect.prepare(_getJson, baseUrl, filter));
      _preparedFor = filter;
    }
    await _waitForTurn();
    final uri = dialect.randomUri(baseUrl, dialect.batchSize, filter);
    final body = await _send(() => _client.get(uri, headers: _headers));
    try {
      return dialect.parseRandom(json.decode(body), baseUrl);
    } on FormatException catch (e) {
      throw SourceUnavailable('$description sent an unexpected response: ${e.message}');
    }
  }

  /// Waits until [ApiDialect.minRequestInterval] has passed since the last
  /// batch request. Each caller books its slot before waiting, so a refill
  /// and a fetch for a new filter still go out one interval apart.
  Future<void> _waitForTurn() async {
    final interval = dialect.minRequestInterval;
    if (interval == Duration.zero) return;
    final now = _now();
    final next = _nextBatchAt;
    final at = next == null || next.isBefore(now) ? now : next;
    _nextBatchAt = at.add(interval);
    if (at.isAfter(now)) await _delay(at.difference(now));
  }

  @override
  Future<void> reportRemote(Question question) async {
    if (!dialect.supportsReport) return;
    final uri = dialect.reportUri(baseUrl, question);
    await _send(() => _client.post(uri, headers: _headers));
  }

  Future<String> _send(Future<http.Response> Function() request) async {
    final http.Response response;
    try {
      response = await request().timeout(timeout);
    } on TimeoutException {
      throw SourceUnavailable('$description did not respond in time.');
    } on http.ClientException catch (e) {
      throw SourceUnavailable('Could not reach $description: ${e.message}');
    } on Exception catch (e) {
      // TLS and other I/O errors the client doesn't wrap.
      throw SourceUnavailable('Could not reach $description: $e');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      final token = this.token;
      throw Unauthorized(token == null || token.isEmpty
          ? '$description needs an access token.'
          : '$description rejected the access token.');
    }
    if (response.statusCode == 429) {
      throw SourceUnavailable(ApiDialect.busyMessage(description));
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SourceUnavailable('$description returned HTTP ${response.statusCode}.');
    }
    return response.body;
  }

  @override
  Future<void> close() async {
    _buffer.clear();
    if (_ownsClient) _client.close();
  }
}
