import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:quizapp/config/source_factory.dart';
import 'package:quizapp/controller/question_repository.dart';
import 'package:quizapp/data/hidden_question_store.dart';
import 'quiz_page.dart';

void main() {
  final repository = QuestionRepository(
    source: questionSourceFromEnvironment(),
    // sqflite has no web implementation.
    hiddenStore: kIsWeb ? SharedPrefsHiddenQuestionStore() : SqfliteHiddenQuestionStore(),
  );
  runApp(QuizApp(repository: repository));
}

class QuizApp extends StatelessWidget {
  const QuizApp({super.key, required this.repository});

  final QuestionRepository repository;

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Random Trivia Question',
      theme: ThemeData(
        // This is the theme of your application.
        primarySwatch: Colors.blue,
        useMaterial3: false,
      ),
      home: QuizPage(title: 'Random Trivia Question', repository: repository),
    );
  }
}
