import 'dart:async';
import 'dart:convert' show json, utf8;
import 'dart:io';
import 'question.dart';

class JeopardyQuestionRepository {
  final httpClient = HttpClient();
  final url = 'jservice.io';

  Future<JeopardyQuestion> getRandomQuestion() async {
    final uri = Uri.http(url, '/api/random', {"count": "1"});

    final httpRequest = await httpClient.getUrl(uri);
    final httpResponse = await httpRequest.close();
    if (httpResponse.statusCode != HttpStatus.OK) {
      return null;
    }

    final responseBody = await httpResponse.transform(utf8.decoder).join();
    final jsonResponse = json.decode(responseBody);
    return JeopardyQuestion.fromJson(jsonResponse[0]);
  }
}