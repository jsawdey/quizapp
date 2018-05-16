import 'package:flutter/material.dart';
import 'question_repository.dart';
import 'package:jeopardy_fun/ui/ui.dart';

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
      home: new MyHomePage(title: 'Random Trivia Question'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({Key key, this.title}) : super(key: key);

  final String title;

  @override
  _MyHomePageState createState() => new _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  JeopardyQuestionRepository repository;
  String _answer;
  String _question;
  int _value;
  String _category;
  String _airDate;
  bool _showAnswer;
  bool _showAnswerInfo;

  _MyHomePageState() {
    repository = new JeopardyQuestionRepository();
    _answer = "";
    _question = "";
    _value = 0;
    _category = "";
    _airDate = null;
    _showAnswer = false;
    _showAnswerInfo = false;
  }

  @override
  void initState() {
    super.initState();
    _loadQuestion();
  }

  void _loadQuestion() {
    repository.getRandomQuestion().then((question) {
      setState(() {
        _question = question.question;
        _answer = question.answer;
        _value = question.value;
        _category = question.category;
        _airDate = question.formattedDateTime();
        _showAnswer = false;
        _showAnswerInfo = false;
      });
    });
  }

  void _showAnswerScreen() {
    setState(() {
      _showAnswer = true;
    });
  }

  Widget _buildFloatingButton() {
    if (_showAnswer) {
      return new FloatingActionButton(
        onPressed: _loadQuestion,
        tooltip: 'Load Random Question',
        child: new Icon(Icons.refresh),
      );
    } else {
      return new FloatingActionButton(
        onPressed: _showAnswerScreen,
        tooltip: "Show Answer",
        child: new Icon(Icons.question_answer),
      );
    }
  }

  Widget _buildInfoButton() {
    if (_showAnswer) {
      return new IconButton(
          icon: new Icon(Icons.info_outline),
          onPressed: () {
            setState(() {
              _showAnswerInfo = !_showAnswerInfo;
            });
          }
      );
    } else {
      return new IconButton(
          icon: new Icon(Icons.info_outline),
          onPressed: null,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called.
    return new Scaffold(
      appBar: new AppBar(
        title: new Text(widget.title),
      ),
      body: new Container(
        color: Colors.grey,
        child: new Stack(
          children: <Widget>[
            new Positioned.fill(
              child: new QuestionSquareWidget(_category, _question, _answer,
                  _value, _airDate, _showAnswer, _showAnswerInfo),
            ),
            new Positioned(
              child: _buildInfoButton(),
              left: 0.0,
              bottom: 0.0,
            )
          ],
        ),
      ),
      floatingActionButton: _buildFloatingButton(),
    );
  }
}
