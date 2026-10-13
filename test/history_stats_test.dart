import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/model/history.dart';
import 'package:quizapp/model/history_stats.dart';
import 'package:quizapp/model/question.dart';

var _next = 0;

HistoryAnswer answer({bool right = true, String day = '2026-10-13', int utcOffset = 0,
    String namespace = 'jwolle1', String category = 'C', int? round, int? row,
    String? difficulty}) =>
    HistoryAnswer(id: '${_next++}'.padLeft(32, '0'), game: 'g' * 32,
        answeredAt: DateTime.parse('${day}T12:00:00Z'), utcOffset: utcOffset,
        namespace: namespace, key: '${_next++}', category: category,
        format: QuestionFormat.open, round: round, row: row, difficulty: difficulty,
        right: right);

HistoryGame game(String id, {int best = 0, String updated = '2026-10-13T12:00:00Z'}) =>
    HistoryGame(id: id, updatedAt: DateTime.parse(updated), answered: best, right: best,
        best: best, dollars: 0, valued: 0);

void main() {
  final now = DateTime(2026, 10, 13, 18);

  HistoryStats compute(List<HistoryAnswer> answers, [List<HistoryGame> games = const []]) =>
      HistoryStats.compute(answers, games, now: now);

  test('an empty history', () {
    final stats = compute([]);
    expect(stats.isEmpty, isTrue);
    expect(stats.total, Tally.zero);
    expect(stats.total.fraction, 0);
    expect(stats.byRound, isEmpty);
    expect(stats.strongest, isEmpty);
    expect(stats.bestStreak, 0);
  });

  test('totals and the last 30 and 7 days', () {
    final stats = compute([
      answer(day: '2026-10-13'),
      answer(day: '2026-10-07', right: false),   // 7th day back: in both
      answer(day: '2026-10-06'),                 // 8th day back: 30 days only
      answer(day: '2026-09-14', right: false),   // 30th day back
      answer(day: '2026-09-13'),                 // 31st: all time only
    ]);
    expect(stats.total, const Tally(5, 3));
    expect(stats.last30Days, const Tally(4, 2));
    expect(stats.last7Days, const Tally(2, 1));
  });

  test("days are the player's, by each answer's own offset", () {
    // 10 pm on the 6th in New York is 2 am on the 7th in UTC: outside the
    // last 7 days there, though inside them in UTC.
    final late = HistoryAnswer(id: 'x' * 32, game: 'g' * 32,
        answeredAt: DateTime.parse('2026-10-07T02:00:00Z'), utcOffset: -240,
        namespace: 'n', key: 'k', category: 'c', format: QuestionFormat.open, right: true);
    expect(compute([late]).last7Days, Tally.zero);
    expect(compute([late]).last30Days, const Tally(1, 1));
  });

  test('by round, by row and by difficulty, in order', () {
    final stats = compute([
      answer(round: 2, row: 5, right: false),
      answer(round: 1, row: 1),
      answer(round: 1, row: 5),
      answer(round: 3),
      answer(difficulty: 'hard', right: false),
      answer(difficulty: 'easy'),
      answer(difficulty: 'unusual'),
    ]);
    expect(stats.byRound, {1: const Tally(2, 2), 2: const Tally(1, 0), 3: const Tally(1, 1)});
    expect(stats.byRound.keys, [1, 2, 3]);
    expect(stats.byRow, {1: const Tally(1, 1), 5: const Tally(2, 1)});
    expect(stats.byDifficulty.keys, ['easy', 'hard', 'unusual']);
    expect(stats.byDifficulty['hard'], const Tally(1, 0));
  });

  List<HistoryAnswer> category(String name, int right, int answered,
      {String namespace = 'jwolle1'}) => [
        for (var i = 0; i < answered; i++)
          answer(category: name, namespace: namespace, right: i < right),
      ];

  test('strongest and weakest need 10 answers, and more answers break ties', () {
    final stats = compute([
      ...category('NINE', 9, 9),        // too few to count
      ...category('HALF', 5, 10),
      ...category('MOST', 18, 20),
      ...category('MOSTLY', 9, 10),     // the same 90%, fewer answers
      ...category('NONE', 0, 12),
    ]);
    expect(stats.strongest.map((c) => c.category), ['MOST', 'MOSTLY', 'HALF', 'NONE']);
    // Nothing is both strongest and weakest.
    expect(stats.weakest, isEmpty);
  });

  test('five of each at most', () {
    final stats = compute([
      for (var i = 0; i < 12; i++) ...category('C$i', i, 11),
    ]);
    expect(stats.strongest.map((c) => c.category), ['C11', 'C10', 'C9', 'C8', 'C7']);
    expect(stats.weakest.map((c) => c.category), ['C0', 'C1', 'C2', 'C3', 'C4']);
  });

  test('the same name in two sources is two categories', () {
    final stats = compute([
      ...category('SCIENCE', 10, 10, namespace: 'jwolle1'),
      ...category('SCIENCE', 0, 10, namespace: 'opentdb'),
    ]);
    expect(stats.strongest.map((c) => (c.namespace, c.tally)),
        [('jwolle1', const Tally(10, 10)), ('opentdb', const Tally(10, 0))]);
  });

  test('best streak and recent games', () {
    final games = [
      for (var i = 0; i < 12; i++)
        game('$i'.padLeft(32, '0'), best: i == 3 ? 23 : i,
            updated: '2026-10-${(i + 1).toString().padLeft(2, '0')}T12:00:00Z'),
    ];
    final stats = compute([], games);
    expect(stats.isEmpty, isFalse);
    expect(stats.bestStreak, 23);
    expect(stats.recentGames.length, 10);
    expect(stats.recentGames.first.id, '11'.padLeft(32, '0'));
  });
}
