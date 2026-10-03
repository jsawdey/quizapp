import 'package:flutter/material.dart';
import 'package:quizapp/ui/theme.dart';

class QuestionAnswerWidget extends StatelessWidget {
  final String _mainText;
  const QuestionAnswerWidget(this._mainText, {super.key});

  @override
  Widget build(BuildContext context) {
    // Wrap at the panel's width, then scale down only if the text is taller
    // than the panel, so long clues are never cut off.
    return LayoutBuilder(
      builder: (context, constraints) => Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: constraints.maxWidth,
            child: Text(
              _mainText.toUpperCase(),
              textAlign: TextAlign.center,
              style: CustomAppTheme.questionAnswerTextTheme(),
            ),
          ),
        ),
      ),
    );
  }
}
