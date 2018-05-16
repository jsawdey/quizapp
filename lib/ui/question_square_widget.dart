import 'package:flutter/material.dart';
import 'question_answer_box.dart';
import 'question_category_widget.dart';
import 'question_widget.dart';
import 'answer_widget.dart';

//TODO: Implement flip animation for question/answer

class QuestionSquareWidget extends StatelessWidget {
  final int id;
  final String _category;
  final String _question;
  final String _answer;
  final int _value;
  final String _airDate;
  final bool _showAnswer;
  final bool _showAnswerInfo;
  QuestionSquareWidget(this.id, this._category, this._question, this._answer,
      this._value, this._airDate, this._showAnswer, this._showAnswerInfo);

  List<Widget> _buildChildrenWidgets() {
    List<Widget> builder = [];
    builder.add(new QuestionAnswerWrapper(150.0,
        new QuestionCategoryWidget(_category)));
    if (_showAnswer) {
      if (_showAnswerInfo) {
        builder.add(new QuestionAnswerWrapper(350.0,
            _AnswerExtraInfoWidget(_value, _airDate)));
      } else {
        builder.add(new QuestionAnswerWrapper(350.0,
            AnswerWidget(_answer)));
      }
    } else {
      builder.add(new QuestionAnswerWrapper(350.0,
          new QuestionWidget(_question)));
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