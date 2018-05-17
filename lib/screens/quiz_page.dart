import 'package:flutter/material.dart';
import 'dart:async';
import 'package:quizapp/controller/question_repository.dart';
import 'package:quizapp/model/quiz_question.dart';
import 'package:quizapp/ui/quiz_question/quiz_ui_library.dart';

enum DialogAnswer {
  Yes,
  No
}

class QuizPage extends StatefulWidget {
  QuizPage({Key key, this.title}) : super(key: key);

  final String title;

  @override
  _MyHomePageState createState() => new _MyHomePageState();
}

class _MyHomePageState extends State<QuizPage> {
  JServiceQuestionRepository repository;
  QuizQuestion _quizQuestion;
  bool _showAnswer;
  bool _questionReported;
  bool _showOverlay;

  _MyHomePageState() {
    repository = new JServiceQuestionRepository();
    _showAnswer = false;
    _questionReported = false;
    _showOverlay = false;
  }

  @override
  void initState() {
    super.initState();
  }

  Future<Null> _reportError() async {
    switch (await showDialog<DialogAnswer>(
        context: context,
        builder: (BuildContext context) {
          return new SimpleDialog(
            title: const Text('Are you sure you want to report this question as invalid?'),
            children: <Widget>[
              new SimpleDialogOption(
                onPressed: () { Navigator.pop(context, DialogAnswer.Yes); },
                child: const Text('Yes'),
              ),
              new SimpleDialogOption(
                onPressed: () { Navigator.pop(context, DialogAnswer.No); },
                child: const Text('No'),
              ),
            ],
          );
        }
    )) {
      case DialogAnswer.Yes:
      // Notify the server the question is invalid
        repository.markQuestionInvalid(_quizQuestion.id);
        // Mark the question as reported so we don't submit it again
        setState(() {
          _questionReported = true;
        });
        // Load a new question
        setState(() {

        });
        break;
      case DialogAnswer.No:
      // ...
        break;
    }
  }

  Widget _buildOverlay() {
    List<Widget> builder = [];
    builder.add(new Positioned.fill(child: _buildQuestionBody()));
    if (_showOverlay) {
      builder.add(new Positioned.fill(child: new QuestionOverlay(_quizQuestion.rawJson)));
    }
    return new Stack(
      children: builder,
    );
  }

  Widget _buildQuestionAnswerWidget() {
    return new QuizDecorationWrapper(new QuestionAnswerWidget(
        _showAnswer ? _quizQuestion.answer : _quizQuestion.question));
  }

  Widget _buildQuestionBody() {
    return new Container(
      color: Colors.black87,
      child: new Column(
        children: <Widget>[
          new Flexible(
            flex: 2,
            child: new QuizDecorationWrapper(
                new QuestionCategoryWidget(_quizQuestion.category)),
          ),
          new Flexible(
              flex: 4,
              child: new GestureDetector(
                onTap: () {
                  setState(() {
                    _showAnswer = !_showAnswer;
                  });
                },
                child: _buildQuestionAnswerWidget(),
              )
          ),
          new Flexible(
            flex: 1,
            child: new Center(
              child: new FlatButton(
                  padding: const EdgeInsets.all(4.0),
                  onPressed: _questionReported ? null : _reportError,
                  child: new Text(
                    'Report Question',
                    style: new TextStyle(
                      color: _questionReported ? Colors.black38 : Colors.white,
                      decoration: TextDecoration.underline,
                    ),
                  )
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called.
    return new Scaffold(
      appBar: new AppBar(
        title: new Text(widget.title),
        actions: <Widget>[
          new IconButton(icon: new Icon(Icons.info), onPressed: () {
            setState(() {
              _showOverlay = !_showOverlay;
            });
          })
        ],
      ),
      body: new FutureBuilder(
        future: repository.getRandomQuestion(),
        builder: (context, snapshot) {
          switch (snapshot.connectionState) {
            case ConnectionState.none:
            case ConnectionState.waiting:
              return new CircularProgressIndicator();
            default:
              _quizQuestion = snapshot.data;
              _showAnswer = false;
              _questionReported = false;
              _showOverlay = false;
              return _buildOverlay();
          }
        },
      ),
      floatingActionButton: new FloatingActionButton(
        onPressed: () {setState(() {});},
        tooltip: 'Load Random Question',
        child: new Icon(Icons.refresh),
      ),
    );
  }
}