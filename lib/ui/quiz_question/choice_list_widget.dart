import 'package:flutter/material.dart';
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

  static const _right = Color(0xFF2E7D32);
  static const _wrong = Color(0xFFC62828);

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
    final Color background;
    final Color foreground;
    IconData? icon;
    String? iconLabel;
    if (picked == null) {
      background = CustomAppTheme.boardBlue;
      foreground = Colors.white;
    } else if (isAnswer) {
      background = _right;
      foreground = Colors.white;
      icon = Icons.check;
      iconLabel = 'Right answer';
    } else if (choice == picked) {
      background = _wrong;
      foreground = Colors.white;
      icon = Icons.close;
      iconLabel = 'Your pick, wrong';
    } else {
      background = CustomAppTheme.boardBlue;
      foreground = Colors.white38;
    }
    return Padding(
      padding: const EdgeInsets.all(4.0),
      child: TextButton(
        key: ValueKey('choice-$index'),
        style: TextButton.styleFrom(
          backgroundColor: background,
          disabledBackgroundColor: background,
          foregroundColor: foreground,
          disabledForegroundColor: foreground,
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
          minimumSize: Size.zero,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(8.0))),
        ),
        onPressed: picked == null ? () => onPick(choice) : null,
        child: Row(
          children: <Widget>[
            if (numbered)
              Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: Text('${index + 1}', style: CustomAppTheme.choiceNumberTextTheme()),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(
                    width: constraints.maxWidth,
                    child: Text(choice, textAlign: TextAlign.center,
                        style: CustomAppTheme.choiceTextTheme().copyWith(color: foreground)),
                  ),
                ),
              ),
            ),
            if (icon != null)
              Padding(
                padding: const EdgeInsets.only(left: 8.0),
                child: Icon(icon, semanticLabel: iconLabel),
              ),
          ],
        ),
      ),
    );
  }
}
