import 'package:flutter/material.dart';
import 'package:quizapp/ui/quiz_question/board_button.dart';
import 'package:quizapp/ui/theme.dart';

/// The options of a multiple-choice or true/false question, one button each.
///
/// Once [picked] is set the buttons stop responding, the right choice turns
/// green with a tick, and a wrong pick turns red with a cross.
class ChoiceListWidget extends StatelessWidget {
  final List<String> choices;
  final String answer;
  final String? picked;
  final ValueChanged<String> onPick;

  /// Whether to number the buttons, for the number-key shortcuts.
  final bool numbered;

  /// From this width on, choices sit in two columns.
  static const twoColumnWidth = 560.0;

  const ChoiceListWidget({super.key, required this.choices, required this.answer,
    required this.picked, required this.onPick, this.numbered = false});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      // True or false fits side by side on any screen.
      final columns = choices.length == 2 || constraints.maxWidth >= twoColumnWidth ? 2 : 1;
      return Column(
        children: <Widget>[
          for (var row = 0; row * columns < choices.length; row++)
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (var i = row * columns; i < (row + 1) * columns; i++)
                    Expanded(child: i < choices.length ? _button(i) : const SizedBox()),
                ],
              ),
            ),
        ],
      );
    });
  }

  Widget _button(int index) {
    final choice = choices[index];
    final picked = this.picked;
    final isAnswer = choice == answer;
    var background = CustomAppTheme.boardBlue;
    var foreground = Colors.white;
    IconData? icon;
    String? iconLabel;
    if (picked != null && isAnswer) {
      background = CustomAppTheme.right;
      icon = Icons.check;
      iconLabel = 'Right answer';
    } else if (picked != null && choice == picked) {
      background = CustomAppTheme.wrong;
      icon = Icons.close;
      iconLabel = 'Your pick, wrong';
    } else if (picked != null) {
      foreground = Colors.white38;
    }
    return BoardButton(
      buttonKey: ValueKey('choice-$index'),
      label: choice,
      background: background,
      foreground: foreground,
      number: numbered ? index + 1 : null,
      icon: icon,
      iconLabel: iconLabel,
      onPressed: picked == null ? () => onPick(choice) : null,
    );
  }
}
