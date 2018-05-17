import 'package:flutter/material.dart';
import 'package:quizapp/ui/theme.dart';

class QuestionAnswerWidget extends StatelessWidget {
  final String _mainText;
  QuestionAnswerWidget(this._mainText);

  @override
  Widget build(BuildContext context) {
    return new Center(
      child: new Text(
        _mainText == null ? '' : _mainText.toUpperCase(),
        textAlign: TextAlign.center,
        style: CustomAppTheme.questionAnswerTextTheme(),
      ),
    );
  }
}