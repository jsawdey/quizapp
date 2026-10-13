import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/controller/history_recorder.dart';
import 'package:quizapp/controller/score_keeper.dart';
import 'package:quizapp/data/history_store.dart';
import 'package:quizapp/data/score_store.dart';
import 'package:quizapp/model/question.dart';
import 'package:quizapp/model/score.dart';

import 'support/fakes.dart';

/// Fails every read or write while [fail] is set.
class FailingScoreStore extends InMemoryScoreStore {
  bool fail = true;

  @override
  Future<Score> read() async {
    if (fail) throw StateError('read failed');
    return super.read();
  }

  @override
  Future<void> write(Score score) async {
    if (fail) throw StateError('write failed');
    return super.write(score);
  }
}

void main() {
  final today = DateTime(2026, 10, 11);
  final clue1 = fakeQuestion('1', round: 1, value: 200);
  final clue2 = fakeQuestion('2', round: 1, value: 400);
  final clue3 = fakeQuestion('3', round: 1, value: 600);

  late InMemoryScoreStore store;
  late ScoreKeeper keeper;

  setUp(() {
    store = InMemoryScoreStore();
    keeper = ScoreKeeper(store: store, now: () => today);
  });

  Future<void> answer(Question question, bool right) {
    keeper.show(question);
    return keeper.record(right: right);
  }

  test('load reads the saved game', () async {
    final saved = Score(answered: 3, right: 2, streak: 1, best: 2, dollars: 400,
        valued: 3, started: today);
    final loaded = await ScoreKeeper.load(InMemoryScoreStore(saved));
    expect(loaded.score, saved);
  });

  test('load starts empty when the saved game cannot be read', () async {
    final loaded = await ScoreKeeper.load(FailingScoreStore());
    expect(loaded.score, Score.empty);
  });

  test('records results and saves them', () async {
    await answer(clue1, true);
    await answer(clue2, false);
    final expected = Score.empty
        .record(clue1, right: true, now: today)
        .record(clue2, right: false, now: today);
    expect(keeper.score, expected);
    expect(store.score, expected);
  });

  test('record needs a question showing', () {
    expect(() => keeper.record(right: true), throwsStateError);
  });

  test('a change of mind replaces the result, streak and best included', () async {
    await answer(clue1, true);
    await answer(clue2, true);
    keeper.show(clue3);
    final before = keeper.score;

    await keeper.record(right: true);
    final rightOnce = keeper.score;
    expect(rightOnce.best, 3);

    await keeper.record(right: false);
    expect(keeper.score, before.record(clue3, right: false, now: today));
    expect(keeper.score.best, 2);

    await keeper.record(right: true);
    expect(keeper.score, rightOnce);
    expect(store.score, rightOnce);
  });

  test('show starts a new question, so a result adds to the score', () async {
    await answer(clue1, true);
    // The same question again, as a source can serve it twice.
    await answer(clue1, true);
    expect(keeper.score.answered, 2);
    expect(keeper.score.streak, 2);
  });

  test('skip ends the streak only when the question has no result', () async {
    await answer(clue1, true);
    await keeper.skip();
    expect(keeper.score.streak, 1);

    keeper.show(clue2);
    await keeper.skip();
    expect(keeper.score.streak, 0);
    expect(keeper.score.best, 1);
    expect(keeper.score.answered, 1);
    expect(store.score.streak, 0);
  });

  test('skip does nothing before a question shows', () async {
    keeper = ScoreKeeper(store: store,
        initial: const Score(answered: 1, right: 1, streak: 1, best: 1));
    await keeper.skip();
    expect(keeper.score.streak, 1);
  });

  test('newGame clears the score, and a later result counts in the new game', () async {
    await answer(clue1, true);
    keeper.show(clue2);
    await keeper.record(right: true);
    await keeper.newGame();
    expect(keeper.score, Score.empty);
    expect(store.score, Score.empty);

    // A change of mind after a new game doesn't bring the old game back.
    await keeper.record(right: false);
    expect(keeper.score, Score.empty.record(clue2, right: false, now: today));
  });

  test('a failed save still counts', () async {
    final failing = FailingScoreStore();
    keeper = ScoreKeeper(store: failing, now: () => today);
    keeper.show(clue1);
    await keeper.record(right: true);
    expect(keeper.score.right, 1);
  });

  test('listeners hear every change, and only changes', () async {
    var heard = 0;
    keeper.addListener(() => heard++);
    keeper.show(clue1);
    expect(heard, 0);
    final saving = keeper.record(right: true);
    // The score changes before the save completes.
    expect(heard, 1);
    expect(keeper.score.right, 1);
    await saving;
    await keeper.record(right: true);
    expect(heard, 1);
    await keeper.record(right: false);
    expect(heard, 2);
    keeper.show(clue2);
    await keeper.skip();
    expect(heard, 2, reason: 'the streak was already 0');
    await keeper.newGame();
    expect(heard, 3);
  });

  group('with a history', () {
    late InMemoryHistoryStore history;
    late HistoryRecorder recorder;

    setUp(() {
      history = InMemoryHistoryStore();
      recorder = HistoryRecorder(store: history);
      keeper = ScoreKeeper(store: store, recorder: recorder, now: () => today);
    });

    test('a result goes into the history with its game', () async {
      await answer(clue2, true);
      final all = await history.all();
      expect(all.answers, hasLength(1));
      final recorded = all.answers.single;
      expect((recorded.key, recorded.value, recorded.right), ('2', 400, true));
      expect(recorded.game, keeper.gameId);
      expect(recorded.answeredAt, today.toUtc());
      final game = all.games.single;
      expect((game.id, game.answered, game.right, game.dollars), (keeper.gameId, 1, 1, 400));
    });

    test('a change of mind replaces the answer; the next question is a new one', () async {
      await answer(clue1, true);
      await keeper.record(right: false);
      var all = await history.all();
      expect(all.answers.single.right, isFalse);
      expect((all.games.single.answered, all.games.single.right), (1, 0));
      await answer(clue2, true);
      all = await history.all();
      expect(all.answers, hasLength(2));
      expect(all.answers.map((a) => a.id).toSet(), hasLength(2));
    });

    test('a new game has a new id, and is saved', () async {
      await answer(clue1, true);
      final first = keeper.gameId;
      await keeper.newGame();
      expect(keeper.gameId, isNot(first));
      expect(store.gameId, keeper.gameId);
      await answer(clue2, true);
      final games = (await history.all()).games;
      expect(games.map((g) => g.id), [first, keeper.gameId]);
    });

    test('load keeps the saved game id, or makes and saves one', () async {
      final saved = InMemoryScoreStore(Score.empty, 'a' * 32);
      expect((await ScoreKeeper.load(saved)).gameId, 'a' * 32);
      final old = InMemoryScoreStore(Score(answered: 3, right: 2, streak: 1, best: 2,
          dollars: 400, valued: 3, started: today));
      final loaded = await ScoreKeeper.load(old, recorder: recorder);
      expect(old.gameId, loaded.gameId);
      expect(loaded.gameId, matches(RegExp(r'^[0-9a-f]{32}$')));
      // The game in progress joins the history with its totals so far.
      loaded.show(clue1);
      await loaded.record(right: true);
      expect((await history.all()).games.single.answered, 4);
    });

    test('a history that fails never stops the game', () async {
      final broken = HistoryRecorder(store: _FailingHistoryStore());
      keeper = ScoreKeeper(store: store, recorder: broken, now: () => today);
      await answer(clue1, true);
      expect(keeper.score.right, 1);
      expect(store.score.right, 1);
    });
  });
}

class _FailingHistoryStore extends InMemoryHistoryStore {
  @override
  Future<void> open() async => throw StateError('no disk');
}
