import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:quizapp/controller/question_repository.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';
import 'package:quizapp/ui/quiz_question/quiz_ui_library.dart';
import 'package:quizapp/ui/theme.dart';

enum DialogAnswer {
  hide,
  cancel
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
  bool _loading = false;
  String? _error;
  bool _showAnswer = false;
  bool _questionHidden = false;
  bool _showOverlay = false;
  /// Whether the error is a missing or rejected token the user can enter.
  bool _needsToken = false;
  final _tokenController = TextEditingController();

  static final _dollars = NumberFormat.simpleCurrency(locale: 'en_US', decimalDigits: 0);

  @override
  void initState() {
    super.initState();
    _loadQuestion();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _loadQuestion() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final question = await widget.repository.next();
      if (!mounted) return;
      setState(() {
        _current = question;
        _showAnswer = false;
        _questionHidden = false;
        _showOverlay = false;
        _needsToken = false;
      });
    } on Unauthorized catch (e) {
      _showError(e.message, needsToken: widget.repository.canSetToken);
    } on SourceUnavailable catch (e) {
      _showError(e.message);
    } on NoQuestionFound catch (e) {
      _showError(e.message);
    } catch (e) {
      debugPrint('Could not load a question: $e');
      _showError('Something went wrong loading a question.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showError(String message, {bool needsToken = false}) {
    if (!mounted) return;
    setState(() {
      _current = null;
      _error = message;
      _needsToken = needsToken;
    });
  }

  Future<void> _connect() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty || _loading) return;
    try {
      await widget.repository.setToken(token);
    } catch (e) {
      debugPrint('Could not save the access token: $e');
    }
    _tokenController.clear();
    await _loadQuestion();
  }

  Future<void> _hideQuestion() async {
    final current = _current;
    if (current == null) return;
    final reported = widget.repository.canReport(current);
    final answer = await showDialog<DialogAnswer>(
        context: context,
        builder: (BuildContext context) {
          return SimpleDialog(
            title: const Text('Hide this question?'),
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(24.0, 0.0, 24.0, 8.0),
                child: Text(reported
                    ? "You won't see it again. It will also be reported to "
                        '${widget.repository.reportTarget}.'
                    : "You won't see it again."),
              ),
              SimpleDialogOption(
                onPressed: () { Navigator.pop(context, DialogAnswer.hide); },
                child: const Text('Hide'),
              ),
              SimpleDialogOption(
                onPressed: () { Navigator.pop(context, DialogAnswer.cancel); },
                child: const Text('Cancel'),
              ),
            ],
          );
        }
    );
    if (answer != DialogAnswer.hide || !mounted) return;
    // Hide the question (the repository reports it to the source in the
    // background) before loading the next one, so it can't come straight back.
    try {
      await widget.repository.hide(current);
    } catch (error) {
      debugPrint('Could not hide question ${current.key}: $error');
    }
    if (!mounted) return;
    setState(() {
      _questionHidden = true;
    });
    await _loadQuestion();
  }

  /// The line under the category: the clue's value, or which round it is.
  static String? _detailFor(JeopardyQuestion question) {
    if (question.isFinalJeopardy) return 'FINAL JEOPARDY';
    if (question.dailyDoubleWager != null) return 'DAILY DOUBLE';
    final value = question.value;
    return value == null || value == 0 ? null : _dollars.format(value);
  }

  Widget _buildOverlay() {
    List<Widget> builder = [];
    builder.add(Positioned.fill(child: _buildQuestionBody()));
    if (_showOverlay) {
      builder.add(Positioned.fill(child: QuestionOverlay(_current?.raw ?? const {})));
    }
    return Stack(
      children: builder,
    );
  }

  Widget _buildQuestionAnswerWidget() {
    final current = _current;
    if (current != null) {
      return GestureDetector(
        onTap: () {
          setState(() {
            _showAnswer = !_showAnswer;
          });
        },
        child: QuizDecorationWrapper(QuestionAnswerWidget(
            _showAnswer ? current.answer : current.question)),
      );
    }
    final error = _error;
    if (error != null && !_loading) {
      return QuizDecorationWrapper(SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(error, textAlign: TextAlign.center,
                style: CustomAppTheme.messageTextTheme()),
            const SizedBox(height: 16.0),
            if (_needsToken) ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320.0),
                child: TextField(
                  controller: _tokenController,
                  obscureText: true,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  cursorColor: Colors.white,
                  decoration: const InputDecoration(
                    labelText: 'Access token',
                    labelStyle: TextStyle(color: Colors.white70),
                    floatingLabelStyle: TextStyle(color: Colors.white),
                    enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white70)),
                    focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white)),
                  ),
                  onSubmitted: (_) => _connect(),
                ),
              ),
              const SizedBox(height: 16.0),
            ],
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white)),
              onPressed: _needsToken ? _connect : _loadQuestion,
              child: Text(_needsToken ? 'Connect' : 'Retry'),
            ),
          ],
        ),
      ));
    }
    return QuizDecorationWrapper(Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const CircularProgressIndicator(color: Colors.white),
        const SizedBox(height: 16.0),
        Text('Loading questions…', style: CustomAppTheme.messageTextTheme()),
      ],
    ));
  }

  Widget _buildQuestionBody() {
    final current = _current;
    final canHide = current != null && !_questionHidden && !_loading;
    return Container(
      color: Colors.black87,
      child: Column(
        children: <Widget>[
          Flexible(
            flex: 2,
            child: QuizDecorationWrapper(current == null
                ? const QuestionCategoryWidget('')
                : QuestionCategoryWidget(current.category,
                    detail: _detailFor(current), comment: current.categoryComment)),
          ),
          Flexible(
              flex: 4,
              child: _buildQuestionAnswerWidget(),
          ),
          Flexible(
            flex: 1,
            child: Center(
              child: TextButton(
                  style: TextButton.styleFrom(padding: const EdgeInsets.all(4.0)),
                  onPressed: canHide ? _hideQuestion : null,
                  child: Text(
                    'Hide Question',
                    style: TextStyle(
                      color: canHide ? Colors.white : Colors.white38,
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
          if (widget.repository.usingFallback && _current != null)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8.0),
              child: Tooltip(
                message: 'Offline: questions are coming from the clue database '
                    'on this device',
                child: Icon(Icons.cloud_off),
              ),
            ),
          IconButton(icon: const Icon(Icons.info), tooltip: 'Show raw data', onPressed: () {
            setState(() {
              _showOverlay = !_showOverlay;
            });
          })
        ],
      ),
      body: _buildOverlay(),
      floatingActionButton: FloatingActionButton(
        onPressed: _loading ? null : _loadQuestion,
        tooltip: 'Load Random Question',
        child: const Icon(Icons.refresh),
      ),
    );
  }
}
