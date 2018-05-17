import 'package:flutter/material.dart';
import 'package:quizapp/screens/quiz_page.dart';

void main() => runApp(new QuizApp());

class QuizApp extends StatelessWidget {
  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return new MaterialApp(
      title: 'Random Trivia Question',
      theme: new ThemeData(
        // This is the theme of your application.
        primarySwatch: Colors.blue,
      ),
      home: new QuizPage(title: 'Random Trivia Question'),
    );
  }
}