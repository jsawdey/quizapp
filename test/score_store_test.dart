import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/data/score_store.dart';
import 'package:quizapp/model/score.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final game = Score(answered: 10, right: 7, streak: 3, best: 5, dollars: 4200,
      valued: 8, started: DateTime(2026, 10, 11));

  group('SharedPrefsScoreStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('reads empty when nothing is saved', () async {
      expect(await SharedPrefsScoreStore().read(), Score.empty);
    });

    test('round trip', () async {
      await SharedPrefsScoreStore().write(game);
      expect(await SharedPrefsScoreStore().read(), game);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SharedPrefsScoreStore.prefsKey),
          '{"answered":10,"right":7,"streak":3,"best":5,"dollars":4200,'
          '"valued":8,"started":"2026-10-11"}');
    });

    test('round trip with a negative dollar score', () async {
      final behind = Score(answered: 2, right: 0, dollars: -1200, valued: 2,
          started: DateTime(2026, 1, 2));
      await SharedPrefsScoreStore().write(behind);
      expect(await SharedPrefsScoreStore().read(), behind);
    });

    test('saving empty removes the saved game', () async {
      final store = SharedPrefsScoreStore();
      await store.write(game);
      await store.write(Score.empty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(SharedPrefsScoreStore.prefsKey), isFalse);
      expect(await store.read(), Score.empty);
    });

    test('a corrupt saved game reads as empty', () async {
      SharedPreferences.setMockInitialValues(
          {SharedPrefsScoreStore.prefsKey: 'not json'});
      expect(await SharedPrefsScoreStore().read(), Score.empty);
    });
  });

  group('decodeScore', () {
    test('reads a game without a start day', () {
      expect(decodeScore('{"answered":0,"right":0,"streak":0,"best":0,'
          '"dollars":0,"valued":0}'), Score.empty);
    });

    test('reads anything unexpected as empty', () {
      const valid = {'answered': 10, 'right': 7, 'streak': 3, 'best': 5,
          'dollars': 4200, 'valued': 8, 'started': '"2026-10-11"'};
      String changed(Map<String, Object> changes) {
        final fields = {...valid, ...changes};
        return '{${fields.entries.map((e) => '"${e.key}":${e.value}').join(',')}}';
      }
      // The baseline parses, so each case below fails for its own reason.
      expect(decodeScore(changed({})), game);
      for (final saved in [
        '', '[]', '42', '{}',
        changed({'answered': '"10"'}),
        changed({'dollars': 1.5}),
        changed({'started': 20261011}),
        changed({'started': '"someday"'}),
        changed({'right': -1}),
        changed({'right': 11}),
        changed({'valued': 11}),
        changed({'streak': 6}),
        changed({'best': 8}),
      ]) {
        expect(decodeScore(saved), Score.empty, reason: saved);
      }
    });
  });

  test('InMemoryScoreStore keeps what was written', () async {
    final store = InMemoryScoreStore();
    expect(await store.read(), Score.empty);
    await store.write(game);
    expect(await store.read(), game);
  });
}
