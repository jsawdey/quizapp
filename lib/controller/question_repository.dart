import 'dart:async';
import 'package:quizapp/model/jservice_api.dart';
import 'package:quizapp/model/question.dart';

class JServiceQuestionRepository {

  Future<JeopardyQuestion> getRandomQuestion() async {
    int invalidCount = 0;
    var jsonResponse;
    do {
      jsonResponse = await JServiceAPI.getRandomJServiceAPIQuestions(1);
      print(jsonResponse[0]['invalid_count'].toString());
      invalidCount = jsonResponse[0]['invalid_count'] == null ? 0 :
        int.parse(jsonResponse[0]['invalid_count']);
    } while (invalidCount != 0);
    return JeopardyQuestion.fromJson(jsonResponse[0]);
  }

  void markQuestionInvalid(int id) {
    print('Marking question ' + id.toString() + ' invalid.');
    JServiceAPI.markJServiceQuestionInvalid(id);
  }



}