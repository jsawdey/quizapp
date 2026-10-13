import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quizapp/data/history_client.dart';
import 'package:quizapp/data/http_question_source.dart';

/// The score history routes of tool/serve_clues.py, in memory: rows upserted
/// by id, each change numbered by a shared seq, fetched in pages.
class FakeHistoryServer {
  String historyId = 'h' * 32;
  bool keepsHistory = true;

  /// While set, every request fails as if the server couldn't be reached.
  bool unreachable = false;

  /// The bearer token required, if any.
  String? token;

  /// Ids of answers the server refuses as malformed.
  final Set<String> rejected = {};

  /// Every POST /v1/history body, in order.
  final List<Map<String, dynamic>> posts = [];
  int fetches = 0;

  int _seq = 0;
  final Map<String, (int, Map<String, dynamic>)> answers = {};
  final Map<String, (int, Map<String, dynamic>)> games = {};

  void addAnswer(Map<String, dynamic> json) => answers[json['id'] as String] = (++_seq, json);
  void addGame(Map<String, dynamic> json) => games[json['id'] as String] = (++_seq, json);

  /// Forgets everything, as a server whose history.db was replaced.
  void replaceHistory(String newId) {
    historyId = newId;
    answers.clear();
    games.clear();
    _seq = 0;
  }

  HistoryClient client({ApiCredentials? credentials}) => HistoryClient(
      baseUrl: Uri.parse('http://nas:8080'),
      credentials: credentials ?? ApiCredentials(token),
      client: MockClient(_handle));

  Future<http.Response> _handle(http.Request request) async {
    if (unreachable) throw http.ClientException('connection refused');
    if (token != null && request.headers['Authorization'] != 'Bearer $token') {
      return http.Response('{"error": "token"}', 401);
    }
    final path = request.url.path;
    if (path == '/v1/info') {
      return _json({'kind': 'clues', if (keepsHistory) 'history': true});
    }
    if (path != '/v1/history' || !keepsHistory) return http.Response('', 404);
    if (request.method == 'POST') {
      final body = json.decode(request.body) as Map<String, dynamic>;
      posts.add(body);
      final sent = (body['answers'] as List).cast<Map<String, dynamic>>();
      if (sent.any((a) => rejected.contains(a['id']))) {
        return http.Response('{"error": "bad answer"}', 400);
      }
      sent.forEach(addAnswer);
      (body['games'] as List).cast<Map<String, dynamic>>().forEach(addGame);
      return http.Response('', 204);
    }
    fetches++;
    final after = int.parse(request.url.queryParameters['after'] ?? '0');
    final limit = int.parse(request.url.queryParameters['limit'] ?? '1000');
    final rows = [
      for (final (seq, a) in answers.values) if (seq > after) (seq, 'answers', a),
      for (final (seq, g) in games.values) if (seq > after) (seq, 'games', g),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final page = rows.take(limit).toList();
    return _json({
      'history': historyId,
      'answers': [for (final (_, table, row) in page) if (table == 'answers') row],
      'games': [for (final (_, table, row) in page) if (table == 'games') row],
      'next': page.isEmpty ? after : page.last.$1,
      'more': rows.length > limit,
    });
  }

  static http.Response _json(Object body) =>
      http.Response(json.encode(body), 200, headers: {'content-type': 'application/json'});
}
