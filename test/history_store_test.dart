import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quizapp/data/history_store.dart';
import 'package:quizapp/model/history.dart';
import 'package:quizapp/model/question.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

HistoryAnswer answer(int n, {bool right = true}) => HistoryAnswer(
    id: '$n'.padLeft(32, '0'), game: 'g' * 32,
    answeredAt: DateTime.utc(2026, 10, 13, 12, n), utcOffset: -240, namespace: 'jwolle1',
    key: '$n', category: 'C', format: QuestionFormat.open, round: 1, row: 2, value: 400,
    right: right);

HistoryGame game({int answered = 1, int minute = 0}) => HistoryGame(id: 'g' * 32,
    started: DateTime(2026, 10, 13), updatedAt: DateTime.utc(2026, 10, 13, 12, minute),
    answered: answered, right: answered, best: answered, dollars: 400 * answered,
    valued: answered);

void main() {
  late Directory dir;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('history_store_test');
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => dir.delete(recursive: true));

  SqfliteHistoryStore sqfliteStore() => SqfliteHistoryStore(
      databaseFactory: databaseFactoryFfi, path: () async => p.join(dir.path, 'history.db'));

  // What every store that keeps the whole history does.
  for (final (name, make) in <(String, HistoryStore Function())>[
    ('in memory', InMemoryHistoryStore.new),
    ('sqflite', sqfliteStore),
  ]) {
    group(name, () {
      late HistoryStore store;
      setUp(() async {
        store = make();
        await store.open();
      });
      tearDown(() => store.close());

      test('keeps answers and games, waiting to be sent', () async {
        await store.putAnswer(answer(1));
        await store.putAnswer(answer(2));
        await store.putGame(game());
        final all = await store.all();
        expect(all.answers, [answer(1), answer(2)]);
        expect(all.games, [game()]);
        final unsent = await store.unsent();
        expect(unsent.answers, [answer(1), answer(2)]);
        expect(unsent.games, [game()]);
        expect(await store.unsentCount(), 2);
      });

      test('a change of mind replaces the answer and goes to the back', () async {
        await store.putAnswer(answer(1));
        await store.putAnswer(answer(2));
        await store.putAnswer(answer(1, right: false));
        expect((await store.all()).answers.length, 2);
        expect((await store.unsent()).answers, [answer(2), answer(1, right: false)]);
      });

      test('an older game row never replaces a newer one', () async {
        await store.putGame(game(answered: 2, minute: 5));
        await store.putGame(game(answered: 1, minute: 1));
        expect((await store.all()).games, [game(answered: 2, minute: 5)]);
      });

      test('batches are the oldest first, up to the limit', () async {
        for (var n = 1; n <= 5; n++) {
          await store.putAnswer(answer(n));
        }
        expect((await store.unsent(answers: 3)).answers, [answer(1), answer(2), answer(3)]);
      });

      test('what was sent stops waiting, unless it changed since', () async {
        await store.putAnswer(answer(1));
        await store.putAnswer(answer(2));
        await store.putGame(game());
        final batch = await store.unsent();
        await store.putAnswer(answer(2, right: false));
        await store.markSent(batch);
        expect((await store.unsent()).answers, [answer(2, right: false)]);
        expect((await store.unsent()).games, isEmpty);
        expect((await store.all()).answers.length, 2);
      });

      test("merging adds the server's rows as sent; its own waiting rows win", () async {
        await store.putAnswer(answer(1, right: false));
        await store.merge([answer(1), answer(2)], [game(answered: 3, minute: 9)]);
        final all = await store.all();
        expect(all.answers.toSet(), {answer(1, right: false), answer(2)});
        expect(all.games, [game(answered: 3, minute: 9)]);
        expect((await store.unsent()).answers, [answer(1, right: false)]);
        expect((await store.unsent()).games, isEmpty);
      });

      test('merging keeps a newer game row', () async {
        await store.putGame(game(answered: 5, minute: 9));
        await store.markSent(await store.unsent());
        await store.merge([], [game(answered: 3, minute: 1)]);
        expect((await store.all()).games, [game(answered: 5, minute: 9)]);
      });

      test('everything can be sent again', () async {
        await store.merge([answer(1)], [game()]);
        expect(await store.unsentCount(), 0);
        await store.resendAll();
        expect((await store.unsent()).answers, [answer(1)]);
        expect((await store.unsent()).games, [game()]);
      });

      test('keeps its sync state', () async {
        expect((await store.syncState()).cursor, 0);
        final synced = DateTime.utc(2026, 10, 13, 18);
        await store.saveSyncState(
            HistorySyncState(historyId: 'h' * 32, cursor: 42, lastSynced: synced));
        final state = await store.syncState();
        expect((state.historyId, state.cursor, state.lastSynced), ('h' * 32, 42, synced));
      });
    });
  }

  test('the sqflite store survives reopening', () async {
    final first = sqfliteStore();
    await first.open();
    await first.putAnswer(answer(1));
    await first.merge([answer(2)], []);
    await first.saveSyncState(const HistorySyncState(historyId: 'h', cursor: 7));
    await first.close();

    final second = sqfliteStore();
    await second.open();
    expect((await second.all()).answers.toSet(), {answer(1), answer(2)});
    expect((await second.unsent()).answers, [answer(1)]);
    expect((await second.syncState()).cursor, 7);
    await second.close();
  });

  group('the web store', () {
    test('keeps only what is waiting to be sent', () async {
      final store = SharedPrefsHistoryStore();
      await store.open();
      expect(store.keepsHistory, isFalse);
      await store.putAnswer(answer(1));
      await store.putGame(game());
      await store.merge([answer(2)], []);
      expect((await store.all()).answers, isEmpty);
      await store.markSent(await store.unsent());
      expect(await store.unsentCount(), 0);
      expect((await store.unsent()).games, isEmpty);
    });

    test('survives a reload', () async {
      final first = SharedPrefsHistoryStore();
      await first.open();
      await first.putAnswer(answer(1));
      await first.putGame(game());
      await first.saveSyncState(const HistorySyncState(historyId: 'h'));

      final second = SharedPrefsHistoryStore();
      await second.open();
      expect((await second.unsent()).answers, [answer(1)]);
      expect((await second.unsent()).games, [game()]);
      expect((await second.syncState()).historyId, 'h');
    });

    test('drops the oldest beyond its cap', () async {
      final store = SharedPrefsHistoryStore(maxUnsent: 2);
      await store.open();
      for (var n = 1; n <= 3; n++) {
        await store.putAnswer(answer(n));
      }
      expect((await store.unsent()).answers, [answer(2), answer(3)]);
    });

    test('a queue that cannot be read starts empty', () async {
      SharedPreferences.setMockInitialValues({SharedPrefsHistoryStore.prefsKey: '{nope'});
      final store = SharedPrefsHistoryStore();
      await store.open();
      expect(await store.unsentCount(), 0);
    });
  });
}
