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
/// buffer, refilling it in the background before it runs out.
class HttpQuestionSource extends QuestionSource {
  static const batchSize = 10;
  static const refillAt = 3;

  /// Batches to try before giving up on a filter the server can't apply.
  static const maxFetchesPerQuestion = 3;

  final Uri baseUrl;
  final ApiDialect dialect;
  final ApiCredentials credentials;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;

  final Queue<Question> _buffer = Queue();
  QuestionFilter _bufferFilter = QuestionFilter.any;
  Future<void>? _refill;
  QuestionFilter? _refillFilter;

  /// Sends [token], or whatever [credentials] holds when the request is made.
  HttpQuestionSource({required this.baseUrl, required this.dialect, String? token,
    ApiCredentials? credentials, this.timeout = const Duration(seconds: 8),
    http.Client? client})
      : credentials = credentials ?? ApiCredentials(token),
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  String? get token => credentials.token;

  @override
  String get description => baseUrl.host;

  @override
  bool get supportsRemoteReport => dialect.supportsReport;

  @override
  Set<FilterKind> get supportedFilters => dialect.supportedFilters;

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
          if (_buffer.length <= refillAt) _refillInBackground(filter);
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

  /// Fetches one batch into the buffer and returns how many questions it added.
  Future<int> _fetchBatch(QuestionFilter filter) async {
    final uri = dialect.randomUri(baseUrl, batchSize, filter);
    final body = await _send(() => _client.get(uri, headers: _headers));
    final List<Question> questions;
    try {
      questions = dialect.parseRandom(json.decode(body), baseUrl);
    } on FormatException catch (e) {
      throw SourceUnavailable('$description sent an unexpected response: ${e.message}');
    }
    // Drop the batch if the filter changed while it was in flight.
    if (filter != _bufferFilter) return 0;
    _buffer.addAll(questions);
    return questions.length;
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
