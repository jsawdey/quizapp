import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/score.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the game being played is kept between launches.
abstract class ScoreStore {
  /// The saved game, or [Score.empty] if there is none.
  Future<Score> read();
  Future<void> write(Score score);
}

/// Keeps the game in memory only. Used by tests.
class InMemoryScoreStore implements ScoreStore {
  Score score;
  InMemoryScoreStore([this.score = Score.empty]);

  @override
  Future<Score> read() async => score;

  @override
  Future<void> write(Score score) async => this.score = score;
}

/// Keeps the game with shared_preferences, as JSON such as
/// `{"answered":10,"right":7,"streak":3,"best":5,"dollars":4200,"valued":8,"started":"2026-10-11"}`.
class SharedPrefsScoreStore implements ScoreStore {
  static const prefsKey = 'score';

  final Future<SharedPreferences> Function() _prefs;

  SharedPrefsScoreStore({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance;

  @override
  Future<Score> read() async {
    final saved = (await _prefs()).getString(prefsKey);
    return saved == null ? Score.empty : decodeScore(saved);
  }

  @override
  Future<void> write(Score score) async {
    final prefs = await _prefs();
    if (score.isEmpty) {
      await prefs.remove(prefsKey);
    } else {
      await prefs.setString(prefsKey, encodeScore(score));
    }
  }
}

@visibleForTesting
String encodeScore(Score score) {
  final started = score.started;
  return json.encode({
    'answered': score.answered,
    'right': score.right,
    'streak': score.streak,
    'best': score.best,
    'dollars': score.dollars,
    'valued': score.valued,
    if (started != null) 'started': isoDate(started),
  });
}

/// Reads what [encodeScore] wrote. Anything unreadable, or counts that can't
/// go together, is [Score.empty], so a bad saved value can't stop the app.
@visibleForTesting
Score decodeScore(String saved) {
  final Object? decoded;
  try {
    decoded = json.decode(saved);
  } on FormatException {
    return Score.empty;
  }
  if (decoded is! Map<String, dynamic>) return Score.empty;
  final answered = decoded['answered'];
  final right = decoded['right'];
  final streak = decoded['streak'];
  final best = decoded['best'];
  final dollars = decoded['dollars'];
  final valued = decoded['valued'];
  final started = decoded['started'];
  if (answered is! int || right is! int || streak is! int || best is! int ||
      dollars is! int || valued is! int || (started != null && started is! String)) {
    return Score.empty;
  }
  final startedOn = started == null ? null : DateTime.tryParse(started as String);
  if (right < 0 || right > answered || valued < 0 || valued > answered ||
      streak < 0 || streak > best || best > right ||
      (started != null && startedOn == null)) {
    return Score.empty;
  }
  return Score(answered: answered, right: right, streak: streak, best: best,
      dollars: dollars, valued: valued, started: startedOn);
}
