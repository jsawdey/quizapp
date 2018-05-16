import 'package:flutter/material.dart';
import 'question_answer_box.dart';

//TODO: Implement flip animation for question/answer
//TODO: Make info icon button clickable

class QuestionSquareWidget extends StatelessWidget {
  final String _category;
  final String _question;
  final String _answer;
  final int _value;
  final String _airDate;
  final bool _showAnswer;
  final bool _showAnswerInfo;
  QuestionSquareWidget(this._category, this._question, this._answer,
      this._value, this._airDate, this._showAnswer, this._showAnswerInfo);

  List<Widget> _buildChildrenWidgets() {
    List<Widget> builder = [];
    builder.add(new QuestionAnswerWrapper(150.0,
        new _QuestionCategoryWidget(_category)));
    if (_showAnswer) {
      if (_showAnswerInfo) {
        builder.add(new QuestionAnswerWrapper(350.0,
            _AnswerExtraInfoWidget(_value, _airDate)));
      } else {
        builder.add(new QuestionAnswerWrapper(350.0,
            _AnswerWidget(_answer)));
      }
    } else {
      builder.add(new QuestionAnswerWrapper(350.0,
          new _QuestionWidget(_question)));
    }
    return builder;
  }

  @override
  Widget build(BuildContext context) {
    return new Column(
      children: _buildChildrenWidgets(),
    );
  }
}

class _QuestionCategoryWidget extends StatelessWidget {
  final String _category;
  _QuestionCategoryWidget(this._category);


  @override
  Widget build(BuildContext context) {
    return new Text(
      _category == null ? '' : _category.toUpperCase(),
      style: new TextStyle(
        fontFamily: 'Swiss911',
        fontSize: 36.0,
        color: Colors.white,
      ),
    );
  }
}

class _QuestionWidget extends StatelessWidget {
  final String _question;
  _QuestionWidget(this._question);

  @override
  Widget build(BuildContext context) {
    return new Text(
      _question == null ? '' : _question.toUpperCase(),
      textAlign: TextAlign.center,
      style: new TextStyle(
        fontFamily: 'Korinna',
        fontSize: 28.0,
        color: Colors.white,
      ),
    );
  }
}

class _AnswerWidget extends StatelessWidget {
  final String _answer;
  _AnswerWidget(this._answer);

  @override
  Widget build(BuildContext context) {
    return new Stack(
      alignment: Alignment.center,
      children: <Widget>[
        new Positioned.fill(
          child: new Padding(
            padding: const EdgeInsets.all(30.0),
            child: new Center(
              child: new Text(
                _answer == null ? '' : _answer.toUpperCase(),
                textAlign: TextAlign.center,
                style: new TextStyle(
                  fontFamily: 'Korinna',
                  fontSize: 28.0,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
        new Positioned(
            top: 0.0,
            right: 0.0,
            child: new IconButton(
                icon: new Icon(Icons.info_outline),
                onPressed: null)
        ),
      ],
    );
  }
}

class _AnswerExtraInfoWidget extends StatelessWidget {
  final int _value;
  final String _airDate;
  _AnswerExtraInfoWidget(this._value, this._airDate);

  @override
  Widget build(BuildContext context) {
    return new Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        new Padding(
          padding: const EdgeInsets.all(30.0),
          child: new Center(
            child: new Text(
              _value == null ? '' : 'Value: \$' + _value.toString(),
              textAlign: TextAlign.center,
              style: new TextStyle(
                fontFamily: 'Korinna',
                fontSize: 28.0,
                color: Colors.white,
              ),
            ),
          ),
        ),
        new Padding(
          padding: const EdgeInsets.all(30.0),
          child: new Center(
            child: new Text(
              _airDate == null ? '' : 'Air Date: ' + _airDate,
              textAlign: TextAlign.center,
              style: new TextStyle(
                fontFamily: 'Korinna',
                fontSize: 28.0,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }
}