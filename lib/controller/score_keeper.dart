import 'package:flutter/foundation.dart';
import 'package:quizapp/controller/history_recorder.dart';
import 'package:quizapp/data/score_store.dart';
import 'package:quizapp/model/history.dart';
import 'package:quizapp/model/question.dart';
import 'package:quizapp/model/score.dart';

/// Keeps score for the questions the page shows, saves the game, and gives
/// each result to the score history if there is a [recorder].
///
/// The page calls [show] for each new question, then [record] when it's
/// answered or [skip] when the player moves on. See docs/scoring-plan.md
/// and docs/history-plan.md.
class ScoreKeeper extends ChangeNotifier {
  final ScoreStore store;

  /// Where results go in the score history; none if null.
  final HistoryRecorder? recorder;

  final DateTime Function() _now;
  Score _score;

  /// The game's id in the history.
  String _gameId;

  Question? _showing;

  /// The history id of the result for the question showing, made with its
  /// first result, so a change of mind replaces that answer.
  String? _answerId;

  /// The score from before the question showing got its first result, so a
  /// change of mind recomputes from it; null while it has no result.
  Score? _before;

  ScoreKeeper({required this.store, Score initial = Score.empty, String? gameId,
    this.recorder, @visibleForTesting DateTime Function()? now})
      : _score = initial,
        _gameId = gameId ?? newHistoryId(),
        _now = now ?? DateTime.now;

  /// A keeper for the game saved in [store]. A game that can't be read is
  /// logged and starts empty. A game saved without a history id (from before
  /// the history) gets one.
  static Future<ScoreKeeper> load(ScoreStore store, {HistoryRecorder? recorder}) async {
    var saved = Score.empty;
    String? gameId;
    try {
      saved = await store.read();
      gameId = await store.readGameId();
    } catch (error) {
      debugPrint('Could not read the saved score: $error');
    }
    final keeper = ScoreKeeper(store: store, initial: saved, gameId: gameId,
        recorder: recorder);
    if (gameId == null) await keeper._saveGameId();
    return keeper;
  }

  Score get score => _score;

  /// The game's id in the score history.
  String get gameId => _gameId;

  /// [question] is showing now; results from here on are for it.
  void show(Question question) {
    _showing = question;
    _before = null;
    _answerId = null;
  }

  /// Counts the question showing as got [right]. Called again for the same
  /// question, it replaces the earlier result. The returned future completes
  /// once the game is saved and the result is in the history; the score
  /// changes straight away.
  Future<void> record({required bool right}) {
    final question = _showing;
    if (question == null) throw StateError('No question is showing');
    final before = _before ??= _score;
    final now = _now();
    final saved = _set(before.record(question, right: right, now: now));
    return Future.wait([saved, _remember(question, right, now)]);
  }

  /// Gives the result to the history. A failure is only logged: the game
  /// goes on without it.
  Future<void> _remember(Question question, bool right, DateTime now) async {
    final recorder = this.recorder;
    if (recorder == null) return;
    final id = _answerId ??= newHistoryId();
    try {
      await recorder.record(
          HistoryAnswer.of(question, id: id, game: _gameId, right: right, at: now),
          HistoryGame.of(_gameId, _score, now: now));
    } catch (error) {
      debugPrint('Could not add the answer to the history: $error');
    }
  }

  /// Moving on from the question showing. Without a result, that ends the
  /// streak.
  Future<void> skip() {
    if (_showing == null || _before != null) return Future.value();
    return _set(_score.skipped());
  }

  /// Clears the score and starts a new game in the history. A result for
  /// the question showing after this counts in the new game.
  Future<void> newGame() {
    _before = null;
    _answerId = null;
    _gameId = newHistoryId();
    return Future.wait([_set(Score.empty), _saveGameId()]);
  }

  Future<void> _saveGameId() async {
    try {
      await store.writeGameId(_gameId);
    } catch (error) {
      debugPrint('Could not save the game id: $error');
    }
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
