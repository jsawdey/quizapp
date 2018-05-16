import 'package:flutter/material.dart';

class QuestionWidget extends StatelessWidget {
  final String _question;
  QuestionWidget(this._question);

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