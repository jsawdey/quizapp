import 'package:flutter/material.dart';
import 'package:quizapp/ui/quiz_question/board_button.dart';
import 'package:quizapp/ui/theme.dart';

/// Got it and Missed it, for saying whether you knew the response to an
/// open question.
///
/// The one chosen turns green with a tick or red with a cross. Both stay
/// active, so a mis-tap can be put right.
class SelfReportWidget extends StatelessWidget {
  /// True for Got it, false for Missed it, null before either.
  final bool? gotIt;
  final ValueChanged<bool> onReport;

  /// Whether to number the buttons 1 and 2, for the number-key shortcuts.
  final bool numbered;

  const SelfReportWidget({super.key, required this.gotIt, required this.onReport,
    this.numbered = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(child: _button(true)),
        Expanded(child: _button(false)),
      ],
    );
  }

  Widget _button(bool got) {
    final chosen = gotIt == got;
    return BoardButton(
      buttonKey: ValueKey(got ? 'got-it' : 'missed-it'),
      label: got ? 'Got it' : 'Missed it',
      background: !chosen ? CustomAppTheme.boardBlue
          : got ? CustomAppTheme.right : CustomAppTheme.wrong,
      number: numbered ? (got ? 1 : 2) : null,
      icon: !chosen ? null : got ? Icons.check : Icons.close,
      iconLabel: chosen ? 'Chosen' : null,
      onPressed: () => onReport(got),
    );
  }
}
