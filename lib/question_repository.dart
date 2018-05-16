import 'dart:async';
import 'package:jeopardy_fun/model/jservice_api.dart';
import 'package:jeopardy_fun/model/question.dart';

class JeopardyQuestionRepository {

  Future<JeopardyQuestion> getRandomQuestion() async {
    int invalidCount = 0;
    var jsonResponse;
    do {
      jsonResponse = await JServiceAPI.getRandomJServiceAPIQuestions(1);
      print(jsonResponse[0]['invalid_count']);
      invalidCount = jsonResponse[0]['invalid_count'] == null ? 0 :
        int.parse(jsonResponse[0]['invalid_count']);
    } while (invalidCount != 0);
    return JeopardyQuestion.fromJson(jsonResponse[0]);
  }

  void markQuestionInvalid(int id) {
    var jsonResponse;
    jsonResponse = JServiceAPI.markJServiceQuestionInvalid(id);
    print(jsonResponse);
  }
}