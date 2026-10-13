import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:quizapp/data/api_dialect.dart';
import 'package:quizapp/data/question_source.dart';

/// The headers for a request to an API that may want [token].
Map<String, String> apiHeaders(String? token, {bool json = false}) => {
      'Accept': 'application/json',
      if (json) 'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };

/// Sends [request] to the API called [description] and returns the response
/// body. Throws [SourceUnavailable] if it can't be reached in [timeout],
/// [Unauthorized] for 401 and 403 (saying whether [token] was missing or
/// wrong), and [UnexpectedStatus] for any other status outside 2xx.
Future<String> sendApiRequest(Future<http.Response> Function() request,
    {required String description, required String? token, required Duration timeout}) async {
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
    throw Unauthorized(token == null || token.isEmpty
        ? '$description needs an access token.'
        : '$description rejected the access token.');
  }
  if (response.statusCode == 429) {
    throw SourceUnavailable(ApiDialect.busyMessage(description));
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw UnexpectedStatus(
        '$description returned HTTP ${response.statusCode}.', response.statusCode);
  }
  return response.body;
}
