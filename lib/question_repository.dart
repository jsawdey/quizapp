import 'dart:async';
import 'dart:convert' show json, utf8;
import 'dart:io';
import 'package:jeopardy_fun/model/question.dart';

class JeopardyQuestionRepository {
  final httpClient = HttpClient();
  final url = 'jservice.io';

  Future<dynamic> _getJeopardyAPIQuestion() async {
    final uri = Uri.http(url, '/api/random', {"count": "1"});

    final httpRequest = await httpClient.getUrl(uri);
    final httpResponse = await httpRequest.close();
    if (httpResponse.statusCode != HttpStatus.OK) {
      return null;
    }

    final responseBody = await httpResponse.transform(utf8.decoder).join();
    final jsonResponse = json.decode(responseBody);
    return jsonResponse;
  }

  Future<JeopardyQuestion> getRandomQuestion() async {
    int invalidCount = 0;
    var jsonResponse;
    do {
      jsonResponse = await _getJeopardyAPIQuestion();
      print(jsonResponse[0]['invalid_count']);
      invalidCount = jsonResponse[0]['invalid_count'] == null ? 0 :
        int.parse(jsonResponse[0]['invalid_count']);
    } while (invalidCount != 0);
    return JeopardyQuestion.fromJson(jsonResponse[0]);
  }
}