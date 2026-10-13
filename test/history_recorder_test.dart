import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/controller/history_recorder.dart';
import 'package:quizapp/data/history_store.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/model/history.dart';
import 'package:quizapp/model/question.dart';

import 'support/fake_history_server.dart';

HistoryAnswer answer(int n, {bool right = true, String game = 'g'}) => HistoryAnswer(
    id: '$n'.padLeft(32, '0'), game: game.padRight(32, game),
    answeredAt: DateTime.utc(2026, 10, 13, 12, 0, n % 60), utcOffset: 0,
    namespace: 'jwolle1', key: '$n', category: 'C', format: QuestionFormat.open,
    right: right);

HistoryGame game({String id = 'g', int answered = 1, int second = 0}) => HistoryGame(
    id: id.padRight(32, id), updatedAt: DateTime.utc(2026, 10, 13, 12, 0, second),
    answered: answered, right: answered, best: answered, dollars: 0, valued: 0);

/// Timers the test fires by hand.
class FakeTimers {
  final List<(Duration, void Function())> scheduled = [];
  Timer call(Duration delay, void Function() callback) {
    scheduled.add((delay, callback));
    return _NeverTimer();
  }

  List<Duration> get delays => [for (final (d, _) in scheduled) d];
  void fireLast() => scheduled.last.$2();
}

class _NeverTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => false;
  @override
  int get tick => 0;
}

void main() {
  final now = DateTime.utc(2026, 10, 13, 18);
  late FakeHistoryServer server;
  late InMemoryHistoryStore store;
  late FakeTimers timers;

  setUp(() {
    server = FakeHistoryServer();
    store = InMemoryHistoryStore();
    timers = FakeTimers();
  });

  HistoryRecorder recorder({HistoryStore? withStore, bool withServer = true,
      ApiCredentials? credentials}) =>
      HistoryRecorder(store: withStore ?? store,
          client: withServer ? server.client(credentials: credentials) : null,
          now: () => now, timer: timers.call);

  test('without a server, answers stay on the device', () async {
    final r = recorder(withServer: false);
    await r.record(answer(1), game());
    await r.sync();
    expect(r.offersHistory, isTrue);
    expect(r.serverName, isNull);
    expect((await r.history()).answers, [answer(1)]);
    expect(r.unsentCount, 1);
  });

  test('a result is stored, then sent', () async {
    final r = recorder();
    await r.record(answer(1), game());
    await r.sync();
    expect(server.answers.keys, [answer(1).id]);
    expect(server.games.keys, [game().id]);
    expect(r.unsentCount, 0);
    expect(r.status, HistorySyncStatus.idle);
    expect(r.lastSynced, now);
    expect((await store.syncState()).lastSynced, now);
  });

  test("other devices' answers are fetched into the store", () async {
    server.addAnswer(answer(7, game: 'o').toJson());
    server.addGame(game(id: 'o').toJson());
    final r = recorder();
    await r.open();
    await r.sync();
    final all = await store.all();
    expect(all.answers, [answer(7, game: 'o')]);
    expect(all.games, [game(id: 'o')]);
    expect(r.revision, 1);
    expect((await store.syncState()).cursor, 2);
    // Nothing new: the revision stays.
    await r.sync();
    expect(r.revision, 1);
  });

  test('sends in batches of 500, and fetches in pages', () async {
    for (var n = 0; n < 1100; n++) {
      await store.putAnswer(answer(n));
    }
    final r = recorder();
    await r.open();
    await r.sync();
    expect(server.posts.map((p) => (p['answers'] as List).length), [500, 500, 100]);
    expect(r.unsentCount, 0);
    // 1,100 rows come back in two pages, merged without change; the sync
    // asked for while opening's was running then finds nothing new.
    expect(server.fetches, 3);
    expect((await store.all()).answers.length, 1100);
  });

  test('a server that is down keeps everything and is tried again later', () async {
    server.unreachable = true;
    final r = recorder();
    await r.record(answer(1), game());
    await r.sync();
    expect(r.status, HistorySyncStatus.failed);
    expect(r.error, contains('nas'));
    expect(r.unsentCount, 1);
    expect(timers.delays, [const Duration(minutes: 1)]);

    for (final expected in [5, 15, 15]) {
      timers.fireLast();
      await r.sync();
      expect(timers.delays.last, Duration(minutes: expected));
    }

    server.unreachable = false;
    timers.fireLast();
    await r.sync();
    expect(r.status, HistorySyncStatus.idle);
    expect(server.answers, hasLength(1));
    // The next failure starts from a minute again.
    server.unreachable = true;
    await r.sync();
    expect(timers.delays.last, const Duration(minutes: 1));
  });

  test('a missing token waits for the next sync instead of retrying', () async {
    server.token = 's3cret';
    final credentials = ApiCredentials();
    final r = recorder(credentials: credentials);
    await r.record(answer(1), game());
    await r.sync();
    expect(r.status, HistorySyncStatus.unauthorized);
    expect(timers.scheduled, isEmpty);

    credentials.token = 's3cret';
    await r.sync();
    expect(r.status, HistorySyncStatus.idle);
    expect(server.answers, hasLength(1));
  });

  test('one sync at a time; one asked for meanwhile follows it', () async {
    final r = recorder();
    await r.open();
    await r.sync();
    final fetches = server.fetches;
    await store.putAnswer(answer(1));
    final first = r.sync();
    final second = r.sync();
    await Future.wait([first, second]);
    expect(server.posts, hasLength(1));
    expect(server.fetches - fetches, 2);
  });

  test('an older server gets nothing, and the web shows no history', () async {
    server.keepsHistory = false;
    final web = recorder(withStore: InMemoryHistoryStore(keepsHistory: false));
    await web.record(answer(1), game());
    await web.sync();
    expect(server.posts, isEmpty);
    expect(web.offersHistory, isFalse);
    expect(web.status, HistorySyncStatus.idle);
  });

  test('the web offers the history once its server says it keeps one', () async {
    final web = recorder(withStore: InMemoryHistoryStore(keepsHistory: false));
    expect(web.offersHistory, isFalse);
    await web.open();
    await web.sync();
    expect(web.offersHistory, isTrue);
  });

  test('a row the server refuses is dropped; the rest get through', () async {
    server.rejected.add(answer(2).id);
    final r = recorder();
    await store.putAnswer(answer(1));
    await store.putAnswer(answer(2));
    await store.putAnswer(answer(3));
    await r.open();
    await r.sync();
    expect(server.answers.keys.toSet(), {answer(1).id, answer(3).id});
    expect(r.unsentCount, 0);
    expect(r.status, HistorySyncStatus.idle);
  });

  test('a replaced server history gets everything this device has', () async {
    final r = recorder();
    await r.record(answer(1), game());
    await r.sync();
    server.addAnswer(answer(9, game: 'o').toJson());
    await r.sync();

    server.replaceHistory('n' * 32);
    await r.sync();
    expect(server.answers.keys.toSet(), {answer(1).id, answer(9, game: 'o').id});
    expect(server.games.keys, [game().id]);
    final state = await store.syncState();
    expect(state.historyId, 'n' * 32);
    expect(state.cursor, 3);
  });

  test('the web reads the history from its server, with what still waits', () async {
    server.addAnswer(answer(1).toJson());
    server.addGame(game(answered: 1, second: 1).toJson());
    final webStore = InMemoryHistoryStore(keepsHistory: false);
    final web = recorder(withStore: webStore);
    await web.open();
    await web.sync();
    server.unreachable = true;
    await web.record(answer(2), game(answered: 2, second: 2));
    server.unreachable = false;
    final history = await web.history();
    expect(history.answers.toSet(), {answer(1), answer(2)});
    expect(history.games, [game(answered: 2, second: 2)]);
  });

  test("the web's history fails plainly when its server can't be reached", () async {
    final web = recorder(withStore: InMemoryHistoryStore(keepsHistory: false));
    server.unreachable = true;
    expect(web.history(), throwsA(isA<Exception>()));
  });
}
