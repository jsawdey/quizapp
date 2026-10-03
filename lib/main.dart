import 'package:flutter/material.dart';
import 'quiz_page.dart';

void main() => runApp(const QuizApp());

class QuizApp extends StatelessWidget {
  const QuizApp({super.key});

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
      home: const QuizPage(title: 'Random Trivia Question'),
    );
  }
}
