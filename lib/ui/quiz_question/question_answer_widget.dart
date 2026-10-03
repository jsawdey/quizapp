import 'package:flutter/material.dart';
import 'package:quizapp/ui/theme.dart';

class QuestionAnswerWidget extends StatelessWidget {
  final String _mainText;
  const QuestionAnswerWidget(this._mainText, {super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        _mainText.toUpperCase(),
        textAlign: TextAlign.center,
        style: CustomAppTheme.questionAnswerTextTheme(),
      ),
    );
  }
}
