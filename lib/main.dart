import 'package:flutter/material.dart';
import 'package:quizapp/controller/question_repository.dart';
import 'package:quizapp/data/api_dialect.dart';
import 'package:quizapp/data/hidden_question_store.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'quiz_page.dart';

void main() {
  // jservice.io is gone; the local clue database replaces it in the next step.
  final repository = QuestionRepository(
    source: HttpQuestionSource(
        baseUrl: Uri.parse('http://jservice.io'), dialect: JServiceDialect()),
    hiddenStore: SqfliteHiddenQuestionStore(),
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
