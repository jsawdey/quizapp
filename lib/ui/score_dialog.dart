import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:quizapp/controller/score_keeper.dart';
import 'package:quizapp/ui/score_line_widget.dart';

/// Shows the game's score, with New game to clear it.
Future<void> showScoreDialog(BuildContext context, ScoreKeeper keeper) {
  final score = keeper.score;
  final started = score.started;
  final percent = score.answered == 0 ? 0 : (score.right * 100 / score.answered).round();
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Score'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('${score.right} right out of ${score.answered} ($percent%)'),
          if (score.valued > 0)
            Text('${formatDollars(score.dollars)} from ${score.valued} '
                '${score.valued == 1 ? 'clue' : 'clues'}'),
          Text('Streak ${score.streak}, best ${score.best}'),
          if (started != null)
            Text('Started ${DateFormat.yMMMd('en_US').format(started)}'),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () {
            keeper.newGame();
            Navigator.pop(context);
          },
          child: const Text('New game'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    ),
  );
}
