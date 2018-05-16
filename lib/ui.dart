import 'package:flutter/material.dart';

class JeopardySquareWidget extends StatelessWidget {
  final String _category;
  final String _question;
  final String _answer;
  final bool _showAnswer;
  final VoidCallback _callback;
  JeopardySquareWidget(this._category, this._question, this._answer,
      this._showAnswer, this._callback);

  List<Widget> _buildChildrenWidgets() {
    List<Widget> builder = [];
    builder.add(new _JeopardyCategoryWidget(_category));
    if (_showAnswer) {
      builder.add(new _JeopardyAnswerWidget(_answer));
    } else {
      builder.add(new _JeopardyQuestionWidget(_question));
      builder.add(new Padding(
        padding: const EdgeInsets.all(10.0),
        child: new RaisedButton(
          child: new Text("Show Answer"),
          onPressed: _callback
        ),
      ));
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


class _JeopardyCategoryWidget extends StatelessWidget {
  final String _category;
  _JeopardyCategoryWidget(this._category);

  String _capitalize(String s) {
    if (s == null || s == '') return '';
    String finalString = '';
    for(String word in s.trim().split(' ')) {
      finalString += word[0].toUpperCase() + word.substring(1) + ' ';
    }
    return finalString.trim();
  }

  @override
  Widget build(BuildContext context) {
    return new Container(
      height: 150.0,
      decoration: new BoxDecoration(
        border: new Border.all(width: 4.0, color: Colors.black),
        color: const Color(0xFFFF060CE9),
      ),
      padding: const EdgeInsets.all(4.0),
      alignment: Alignment.center,
      child: new Center(
        child: new Text(
          _category == null ? '' : _capitalize(_category),
          style: new TextStyle(
            fontFamily: 'Swiss911',
            fontSize: 36.0,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _JeopardyQuestionWidget extends StatelessWidget {
  final String _question;
  _JeopardyQuestionWidget(this._question);

  @override
  Widget build(BuildContext context) {
    return new Container(
      height: 300.0,
      decoration: new BoxDecoration(
        color: const Color(0xFFFF060CE9),
      ),
      padding: const EdgeInsets.all(4.0),
      alignment: Alignment.center,
      child: new Center(
        child: new Text(
          _question == null ? '' : _question.toUpperCase(),
          style: new TextStyle(
            fontFamily: 'Korinna Bold',
            fontSize: 28.0,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}


class _JeopardyAnswerWidget extends StatelessWidget {
  final String _answer;
  _JeopardyAnswerWidget(this._answer);

  @override
  Widget build(BuildContext context) {
    return new Container(
      height: 150.0,
      width: 300.0,
      decoration: new BoxDecoration(
        color: const Color(0xFFFF060CE9),
      ),
      padding: const EdgeInsets.all(4.0),
      alignment: Alignment.center,
      child: new Center(
        child: new Text(
          _answer == null ? '' : _answer.toUpperCase(),
          style: new TextStyle(
            fontFamily: 'Korinna Bold',
            fontSize: 24.0,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}