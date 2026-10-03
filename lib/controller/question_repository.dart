import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:quizapp/model/jservice_api.dart';
import 'package:quizapp/model/question.dart';

class JServiceQuestionRepository {

  Future<JeopardyQuestion> getRandomQuestion() async {
    int invalidCount = 0;
    List<dynamic>? jsonResponse;
    do {
      jsonResponse = await JServiceAPI.getRandomJServiceAPIQuestions(1);
      if (jsonResponse == null || jsonResponse.isEmpty) {
        throw Exception('jService did not return a question');
      }
      final count = jsonResponse[0]['invalid_count'];
      debugPrint(count.toString());
      invalidCount = count == null ? 0 : int.parse(count.toString());
    } while (invalidCount != 0);
    return JeopardyQuestion.fromJson(jsonResponse[0]);
  }

  void markQuestionInvalid(int id) {
    debugPrint('Marking question $id invalid.');
    JServiceAPI.markJServiceQuestionInvalid(id);
  }



}
