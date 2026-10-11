import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:quizapp/model/score.dart';

final _dollarFormat = NumberFormat.simpleCurrency(locale: 'en_US', decimalDigits: 0);
final _numberFormat = NumberFormat.decimalPattern('en_US');

/// "$4,200", or "−$400" with a minus sign rather than a hyphen.
String formatDollars(int dollars) =>
    dollars < 0 ? '−${_dollarFormat.format(-dollars)}' : _dollarFormat.format(dollars);

/// The score line's text, such as "7/10 right · streak 3 · $4,200". Dollars
/// only appear once a clue with a value has been scored.
String describeScore(Score score) => [
      '${score.right}/${score.answered} right',
      'streak ${score.streak}',
      if (score.valued > 0) formatDollars(score.dollars),
    ].join(' · ');

/// [describeScore] for a screen reader, such as "Score: 7 right out of 10,
/// streak 3, 4,200 dollars".
String describeScoreAloud(Score score) {
  final dollars = score.dollars;
  return [
    'Score: ${score.right} right out of ${score.answered}',
    'streak ${score.streak}',
    if (score.valued > 0)
      '${dollars < 0 ? 'minus ' : ''}${_numberFormat.format(dollars.abs())} dollars',
  ].join(', ');
}

/// The score at the bottom of the board, as a button that opens the score
/// dialog. Nothing until the game's first result.
class ScoreLineWidget extends StatelessWidget {
  final Score score;
  final VoidCallback onPressed;

  const ScoreLineWidget({super.key, required this.score, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    if (score.answered == 0) return const SizedBox.shrink();
    return TextButton(
      style: TextButton.styleFrom(
          foregroundColor: Colors.white, padding: const EdgeInsets.all(4.0)),
      onPressed: onPressed,
      // Shrinks rather than wraps when a narrow phone can't fit it.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(describeScore(score), semanticsLabel: describeScoreAloud(score)),
      ),
    );
  }
}
