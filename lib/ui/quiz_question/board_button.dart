import 'package:flutter/material.dart';
import 'package:quizapp/ui/theme.dart';

/// A button under the card, for an answer choice or for Got it / Missed it:
/// [label] scaled down to fit, an optional number for its key, and an
/// optional icon once it's been marked right or wrong.
class BoardButton extends StatelessWidget {
  final String label;
  final Color background;
  final Color foreground;

  /// The number key that presses it; not shown if null.
  final int? number;
  final IconData? icon;
  final String? iconLabel;

  /// Null makes the button inactive, keeping its colours.
  final VoidCallback? onPressed;

  /// Goes on the [TextButton] itself.
  final Key? buttonKey;

  const BoardButton({super.key, required this.label, required this.onPressed,
    this.background = CustomAppTheme.boardBlue, this.foreground = Colors.white,
    this.number, this.icon, this.iconLabel, this.buttonKey});

  @override
  Widget build(BuildContext context) {
    final number = this.number;
    final icon = this.icon;
    return Padding(
      padding: const EdgeInsets.all(4.0),
      child: TextButton(
        key: buttonKey,
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
        onPressed: onPressed,
        child: Row(
          children: <Widget>[
            if (number != null)
              Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: Text('$number', style: CustomAppTheme.choiceNumberTextTheme()),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(
                    width: constraints.maxWidth,
                    child: Text(label, textAlign: TextAlign.center,
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
