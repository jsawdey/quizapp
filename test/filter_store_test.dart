import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/data/filter_store.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final nineties = QuestionFilter(rounds: const {1, 2},
      from: DateTime(1990), to: DateTime(1999, 12, 31), boardRows: const {4, 5});

  group('SharedPrefsFilterStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('reads any when nothing is saved', () async {
      expect(await SharedPrefsFilterStore().read(), QuestionFilter.any);
    });

    test('round trip', () async {
      await SharedPrefsFilterStore().write(nineties);
      expect(await SharedPrefsFilterStore().read(), nineties);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SharedPrefsFilterStore.prefsKey),
          '{"rounds":[1,2],"from":"1990-01-01","to":"1999-12-31","rows":[4,5]}');
    });

    test('saving any removes the saved filter', () async {
      final store = SharedPrefsFilterStore();
      await store.write(nineties);
      await store.write(QuestionFilter.any);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(SharedPrefsFilterStore.prefsKey), isFalse);
      expect(await store.read(), QuestionFilter.any);
    });

    test('a corrupt saved filter reads as any', () async {
      SharedPreferences.setMockInitialValues(
          {SharedPrefsFilterStore.prefsKey: 'not json'});
      expect(await SharedPrefsFilterStore().read(), QuestionFilter.any);
    });
  });

  group('decodeFilter', () {
    test('keeps the parts that parse', () {
      expect(decodeFilter('{"from":"2001-01-01"}'), QuestionFilter(from: DateTime(2001)));
      expect(decodeFilter('{"rounds":[3],"to":"soon"}'), const QuestionFilter(rounds: {3}));
      expect(decodeFilter('{"rounds":["one"],"to":"2001-12-31"}'),
          QuestionFilter(to: DateTime(2001, 12, 31)));
      // Saved before board rows existed: any row.
      expect(decodeFilter('{"rounds":[3]}').boardRows, isNull);
      expect(decodeFilter('{"rows":[5,"x"]}'), QuestionFilter.any);
    });

    test('reads anything unexpected as any', () {
      for (final saved in ['', '[]', '42', '{"rounds":[]}', '{"rounds":3}', '{}']) {
        expect(decodeFilter(saved), QuestionFilter.any, reason: saved);
      }
    });
  });

  test('normalized writes every round as no round filter', () {
    expect(const QuestionFilter(rounds: {1, 2, 3}).normalized(), QuestionFilter.any);
    expect(const QuestionFilter(rounds: {1, 2}).normalized(),
        const QuestionFilter(rounds: {1, 2}));
    expect(QuestionFilter(rounds: const {1, 2, 3}, from: DateTime(2001)).normalized(),
        QuestionFilter(from: DateTime(2001)));
  });
}
