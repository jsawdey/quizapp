import 'package:flutter/material.dart';
import 'package:quizapp/controller/question_repository.dart';
import 'package:quizapp/model/question.dart';
import 'package:quizapp/ui/quiz_question/quiz_ui_library.dart';

enum DialogAnswer {
  yes,
  no
}

class QuizPage extends StatefulWidget {
  const QuizPage({super.key, required this.title, required this.repository});

  final String title;
  final QuestionRepository repository;

  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  JeopardyQuestion? _current;
  String _answer = "";
  String _question = "";
  Map<String, dynamic> _json = {};
  bool _showAnswer = false;
  bool _questionReported = false;
  bool _showOverlay = false;
  String _category = "";

  @override
  void initState() {
    super.initState();
    _loadQuestion();
  }

  void _loadQuestion() {
    widget.repository.next().then((question) {
      if (!mounted) return;
      setState(() {
        _current = question;
        _question = question.question;
        _answer = question.answer;
        _category = question.category;
        _json = question.raw;
        _showAnswer = false;
        _questionReported = false;
        _showOverlay = false;
      });
    }).catchError((Object error) {
      debugPrint('Could not load a question: $error');
    });
  }

  Future<void> _reportError() async {
    switch (await showDialog<DialogAnswer>(
        context: context,
        builder: (BuildContext context) {
          return SimpleDialog(
            title: const Text('Are you sure you want to report this question as invalid?'),
            children: <Widget>[
              SimpleDialogOption(
                onPressed: () { Navigator.pop(context, DialogAnswer.yes); },
                child: const Text('Yes'),
              ),
              SimpleDialogOption(
                onPressed: () { Navigator.pop(context, DialogAnswer.no); },
                child: const Text('No'),
              ),
            ],
          );
        }
    )) {
      case DialogAnswer.yes:
        if (!mounted) return;
        // Hide the question on this device (the repository reports it to the
        // source in the background) before loading the next one, so it can't
        // come straight back.
        final current = _current;
        if (current != null) {
          try {
            await widget.repository.hide(current);
          } catch (error) {
            debugPrint('Could not hide question ${current.key}: $error');
          }
        }
        if (!mounted) return;
        // Mark the question as reported so we don't submit it again
        setState(() {
          _questionReported = true;
        });
        // Load a new question
        _loadQuestion();
        break;
      case DialogAnswer.no:
      case null:
      // ...
        break;
    }
  }

  Widget _buildOverlay() {
    List<Widget> builder = [];
    builder.add(Positioned.fill(child: _buildQuestionBody()));
    if (_showOverlay) {
      builder.add(Positioned.fill(child: QuestionOverlay(_json)));
    }
    return Stack(
      children: builder,
    );
  }

  Widget _buildQuestionAnswerWidget() {
    return QuizDecorationWrapper(QuestionAnswerWidget(
        _showAnswer ? _answer : _question));
  }

  Widget _buildQuestionBody() {
    return Container(
      color: Colors.black87,
      child: Column(
        children: <Widget>[
          Flexible(
            flex: 2,
            child: QuizDecorationWrapper(
                QuestionCategoryWidget(_category)),
          ),
          Flexible(
              flex: 4,
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _showAnswer = !_showAnswer;
                  });
                },
                child: _buildQuestionAnswerWidget(),
              )
          ),
          Flexible(
            flex: 1,
            child: Center(
              child: TextButton(
                  style: TextButton.styleFrom(padding: const EdgeInsets.all(4.0)),
                  onPressed: _questionReported ? null : _reportError,
                  child: Text(
                    'Report Question',
                    style: TextStyle(
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: <Widget>[
          IconButton(icon: Icon(Icons.info), onPressed: () {
            setState(() {
              _showOverlay = !_showOverlay;
            });
          })
        ],
      ),
      body: _buildOverlay(),
      floatingActionButton: FloatingActionButton(
        onPressed: _loadQuestion,
        tooltip: 'Load Random Question',
        child: Icon(Icons.refresh),
      ),
    );
  }
}