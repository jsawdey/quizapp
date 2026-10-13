import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:quizapp/data/api_dialect.dart';
import 'package:quizapp/data/api_request.dart';
import 'package:quizapp/data/history_store.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/history.dart';

/// One page of what changed in the server's history after a cursor.
class HistoryPage {
  /// Which history the server holds; it changes if the history is replaced.
  final String historyId;
  final List<HistoryAnswer> answers;
  final List<HistoryGame> games;

  /// The cursor to ask from next, and whether there is more to ask for.
  final int next;
  final bool more;

  const HistoryPage({required this.historyId, this.answers = const [],
    this.games = const [], required this.next, this.more = false});
}

/// The server refused a batch as malformed (HTTP 400): sending it again
/// won't help.
class HistoryRejected implements Exception {
  final String message;
  const HistoryRejected(this.message);

  @override
  String toString() => message;
}

/// Talks to the score history on a `quizapp` server (`tool/serve_clues.py`;
/// docs/history-plan.md §4). Throws as [sendApiRequest] does.
class HistoryClient {
  final Uri baseUrl;
  final ApiCredentials credentials;
  final Duration timeout;
  final http.Client _client;

  HistoryClient({required this.baseUrl, required this.credentials,
    this.timeout = const Duration(seconds: 15), http.Client? client})
      : _client = client ?? http.Client();

  String get description => baseUrl.host;

  Future<String> _send(Future<http.Response> Function() request) => sendApiRequest(request,
      description: description, token: credentials.token, timeout: timeout);

  Uri _uri(String path, [Map<String, String>? query]) =>
      ApiDialect.endpoint(baseUrl, path, query);

  /// Whether the server keeps a history; older servers don't say so.
  Future<bool> keepsHistory() async {
    final body = await _send(() =>
        _client.get(_uri('v1/info'), headers: apiHeaders(credentials.token)));
    try {
      final info = json.decode(body);
      return info is Map<String, dynamic> && info['history'] == true;
    } on FormatException catch (e) {
      throw SourceUnavailable('$description sent an unexpected response: ${e.message}');
    }
  }

  /// Sends [batch]. Throws [HistoryRejected] if the server says it's
  /// malformed.
  Future<void> send(HistoryBatch batch) async {
    try {
      await _send(() => _client.post(_uri('v1/history'),
          headers: apiHeaders(credentials.token, json: true),
          body: json.encode({
            'answers': [for (final a in batch.answers) a.toJson()],
            'games': [for (final g in batch.games) g.toJson()],
          })));
    } on UnexpectedStatus catch (e) {
      if (e.statusCode == 400 || e.statusCode == 413) throw HistoryRejected(e.message);
      rethrow;
    }
  }

  /// What changed after [after], at most [limit] rows.
  Future<HistoryPage> fetch({required int after, int limit = 1000}) async {
    final body = await _send(() => _client.get(
        _uri('v1/history', {'after': '$after', 'limit': '$limit'}),
        headers: apiHeaders(credentials.token)));
    final Object? page;
    try {
      page = json.decode(body);
    } on FormatException catch (e) {
      throw SourceUnavailable('$description sent an unexpected response: ${e.message}');
    }
    if (page is! Map<String, dynamic> || page['history'] is! String ||
        page['answers'] is! List || page['games'] is! List || page['next'] is! int ||
        page['more'] is! bool) {
      throw SourceUnavailable('$description sent an unexpected history page.');
    }
    return HistoryPage(
      historyId: page['history'] as String,
      answers: (page['answers'] as List).map(HistoryAnswer.fromJson).nonNulls.toList(),
      games: (page['games'] as List).map(HistoryGame.fromJson).nonNulls.toList(),
      next: page['next'] as int,
      more: page['more'] as bool,
    );
  }

  void close() => _client.close();
}
