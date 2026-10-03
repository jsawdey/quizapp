import 'dart:async';
import 'dart:collection';
import 'dart:convert' show json;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:quizapp/data/api_dialect.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';

/// Fetches questions from an HTTP API in batches and serves them from a
/// buffer, refilling it in the background before it runs out.
class HttpQuestionSource extends QuestionSource {
  static const batchSize = 10;
  static const refillAt = 3;

  /// Batches to try before giving up on a filter the server can't apply.
  static const maxFetchesPerQuestion = 3;

  final Uri baseUrl;
  final ApiDialect dialect;
  final String? token;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;

  final Queue<JeopardyQuestion> _buffer = Queue();
  QuestionFilter _bufferFilter = QuestionFilter.any;
  Future<void>? _refill;

  HttpQuestionSource({required this.baseUrl, required this.dialect, this.token,
    this.timeout = const Duration(seconds: 8), http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  @override
  String get description => baseUrl.host;

  @override
  bool get supportsRemoteReport => dialect.supportsReport;

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    if (token != null && token!.isNotEmpty) 'Authorization': 'Bearer $token',
  };

  @override
  Future<JeopardyQuestion> randomQuestion({QuestionFilter filter = QuestionFilter.any}) async {
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
      await (_refill ?? _fetchBatch(filter));
    }
  }

  void _refillInBackground(QuestionFilter filter) {
    _refill ??= _fetchBatch(filter).catchError((Object error) {
      // The next randomQuestion call fetches again and reports the error.
      debugPrint('Background refill from $description failed: $error');
    }).whenComplete(() => _refill = null);
  }

  Future<void> _fetchBatch(QuestionFilter filter) async {
    final uri = dialect.randomUri(baseUrl, batchSize, filter);
    final body = await _send(() => _client.get(uri, headers: _headers));
    final List<JeopardyQuestion> questions;
    try {
      questions = dialect.parseRandom(json.decode(body), baseUrl);
    } on FormatException catch (e) {
      throw SourceUnavailable('$description sent an unexpected response: ${e.message}');
    }
    // Drop the batch if the filter changed while it was in flight.
    if (filter == _bufferFilter) _buffer.addAll(questions);
  }

  @override
  Future<void> reportRemote(JeopardyQuestion question) async {
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
