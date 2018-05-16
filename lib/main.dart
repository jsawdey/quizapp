import 'package:flutter/material.dart';
import 'question_repository.dart';
import 'ui.dart';

void main() => runApp(new JeopardyApp());

class JeopardyApp extends StatelessWidget {
  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return new MaterialApp(
      title: 'Random Jeopary Question',
      theme: new ThemeData(
        // This is the theme of your application.
        primarySwatch: Colors.blue,
      ),
      home: new MyHomePage(title: 'Random Jeopardy Question'),
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
  DateTime _airDate;
  bool _showAnswer;

  _MyHomePageState() {
    repository = new JeopardyQuestionRepository();
    _answer = "";
    _question = "";
    _value = 0;
    _category = "";
    _airDate = null;
    _showAnswer = false;
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
        _airDate = question.airDate;
        _showAnswer = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called.
    return new Scaffold(
      appBar: new AppBar(
        title: new Text(widget.title),
      ),
      body: new Center(
        child: new Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            new JeopardySquareWidget(_category, _question, _answer, _showAnswer, () {
              setState(() {
                _showAnswer = true;
              });
            }),
          ],
        ),
      ),
      floatingActionButton: new FloatingActionButton(
        onPressed: _loadQuestion,
        tooltip: 'Load Random Question',
        child: new Icon(_showAnswer ? Icons.refresh : Icons.question_answer),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }
}
