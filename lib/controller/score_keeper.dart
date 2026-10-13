import 'package:flutter/foundation.dart';
import 'package:quizapp/data/score_store.dart';
import 'package:quizapp/model/question.dart';
import 'package:quizapp/model/score.dart';

/// Keeps score for the questions the page shows, and saves the game.
///
/// The page calls [show] for each new question, then [record] when it's
/// answered or [skip] when the player moves on. See docs/scoring-plan.md.
class ScoreKeeper extends ChangeNotifier {
  final ScoreStore store;
  final DateTime Function() _now;
  Score _score;

  Question? _showing;

  /// The score from before the question showing got its first result, so a
  /// change of mind recomputes from it; null while it has no result.
  Score? _before;

  ScoreKeeper({required this.store, Score initial = Score.empty,
    @visibleForTesting DateTime Function()? now})
      : _score = initial,
        _now = now ?? DateTime.now;

  /// A keeper for the game saved in [store]. A game that can't be read is
  /// logged and starts empty.
  static Future<ScoreKeeper> load(ScoreStore store) async {
    var saved = Score.empty;
    try {
      saved = await store.read();
    } catch (error) {
      debugPrint('Could not read the saved score: $error');
    }
    return ScoreKeeper(store: store, initial: saved);
  }

  Score get score => _score;

  /// [question] is showing now; results from here on are for it.
  void show(Question question) {
    _showing = question;
    _before = null;
  }

  /// Counts the question showing as got [right]. Called again for the same
  /// question, it replaces the earlier result. The returned future completes
  /// once the game is saved; the score changes straight away.
  Future<void> record({required bool right}) {
    final question = _showing;
    if (question == null) throw StateError('No question is showing');
    final before = _before ??= _score;
    return _set(before.record(question, right: right, now: _now()));
  }

  /// Moving on from the question showing. Without a result, that ends the
  /// streak.
  Future<void> skip() {
    if (_showing == null || _before != null) return Future.value();
    return _set(_score.skipped());
  }

  /// Clears the score. A result for the question showing after this counts
  /// in the new game.
  Future<void> newGame() {
    _before = null;
    return _set(Score.empty);
  }

  /// Uses [score] and saves it. A failed save is only logged: the score
  /// still counts until the app closes.
  Future<void> _set(Score score) async {
    if (score == _score) return;
    _score = score;
    notifyListeners();
    try {
      await store.write(score);
    } catch (error) {
      debugPrint('Could not save the score: $error');
    }
  }
}
