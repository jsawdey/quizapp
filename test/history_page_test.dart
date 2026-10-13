import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizapp/controller/history_recorder.dart';
import 'package:quizapp/data/history_store.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/model/history.dart';
import 'package:quizapp/model/question.dart';
import 'package:quizapp/ui/history_page.dart';

import 'support/fake_history_server.dart';

var _next = 0;

HistoryAnswer answer({bool right = true, String day = '2026-10-13', String category = 'C',
    String namespace = 'jwolle1', int? round, int? row, String? difficulty, String game = 'g'}) =>
    HistoryAnswer(id: '${_next++}'.padLeft(32, '0'), game: game.padRight(32, game),
        answeredAt: DateTime.parse('${day}T12:00:00Z'), utcOffset: 0, namespace: namespace,
        key: '${_next++}', category: category, format: QuestionFormat.open, round: round,
        row: row, difficulty: difficulty, right: right);

HistoryGame game({String id = 'g', int answered = 40, int right = 29, int best = 7,
    int dollars = 9800, int valued = 30}) =>
    HistoryGame(id: id.padRight(32, id), started: DateTime(2026, 10, 12),
        updatedAt: DateTime.utc(2026, 10, 12, 20), answered: answered, right: right,
        best: best, dollars: dollars, valued: valued);

Timer _noTimer(Duration delay, void Function() callback) => Timer(Duration.zero, () {});

void main() {
  final now = DateTime(2026, 10, 13, 18);
  late InMemoryHistoryStore store;
  late FakeHistoryServer server;

  setUp(() {
    store = InMemoryHistoryStore();
    server = FakeHistoryServer();
  });

  HistoryRecorder recorder({bool withServer = false, HistoryStore? withStore,
      ApiCredentials? credentials}) =>
      HistoryRecorder(store: withStore ?? store, now: () => now, timer: _noTimer,
          client: withServer ? server.client(credentials: credentials) : null);

  Future<void> pumpPage(WidgetTester tester, HistoryRecorder r) async {
    await tester.binding.setSurfaceSize(const Size(360, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: HistoryPage(recorder: r, now: () => now)));
    await tester.pumpAndSettle();
  }

  Future<void> syncAndPump(WidgetTester tester, HistoryRecorder r) async {
    final syncing = r.sync();
    await tester.pumpAndSettle();
    await syncing;
    await tester.pumpAndSettle();
  }

  testWidgets('an empty history says so', (WidgetTester tester) async {
    await pumpPage(tester, recorder());
    expect(find.text('History'), findsOneWidget);
    expect(find.textContaining('No answers yet'), findsOneWidget);
    // No server, nothing about syncing.
    expect(find.textContaining('ync'), findsNothing);
  });

  testWidgets('shows every section from the device\'s history', (WidgetTester tester) async {
    for (final a in [
      answer(round: 1, row: 1),
      answer(round: 2, row: 5, right: false),
      answer(day: '2026-09-01', round: 3),
      answer(namespace: 'opentdb', difficulty: 'easy'),
      answer(namespace: 'opentdb', difficulty: 'hard', right: false),
      for (var i = 0; i < 10; i++) answer(category: 'POTENT POTABLES', right: i < 9),
      for (var i = 0; i < 10; i++)
        answer(namespace: 'opentdb', category: 'Science: Gadgets', right: i < 2),
    ]) {
      await store.putAnswer(a);
    }
    await store.putGame(game());
    await pumpPage(tester, recorder());

    expect(find.text('Overall'), findsOneWidget);
    expect(find.text('All time'), findsOneWidget);
    expect(find.text('14/25 right (56%)'), findsOneWidget);
    expect(find.text('Last 7 days'), findsOneWidget);
    // September 1st is outside both the last 30 and the last 7 days.
    expect(find.text('13/24 right (54%)'), findsNWidgets(2));
    expect(find.text('Jeopardy! clues'), findsOneWidget);
    expect(find.text('Double Jeopardy!'), findsOneWidget);
    expect(find.text('Row 5 (bottom)'), findsOneWidget);
    expect(find.text('Trivia'), findsOneWidget);
    expect(find.text('Easy'), findsOneWidget);
    expect(find.text('Hard'), findsOneWidget);
    expect(find.text('Strongest categories'), findsOneWidget);
    expect(find.text('POTENT POTABLES'), findsOneWidget);
    expect(find.text('Open Trivia Database'), findsWidgets);
    expect(find.text('Weakest categories'), findsNothing);
    expect(find.text('Science: Gadgets'), findsOneWidget);
    expect(find.text('Best streak 7'), findsOneWidget);
    expect(find.text('Oct 12, 2026'), findsOneWidget);
    expect(find.text('29/40 right · best streak 7 · \$9,800'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('says when it last synced and what is still waiting',
      (WidgetTester tester) async {
    server.unreachable = true;
    final r = recorder(withServer: true);
    await r.record(answer(), game());
    await pumpPage(tester, r);
    expect(find.text('Could not sync with nas; trying again soon.'), findsOneWidget);
    expect(find.text('1 answer from this device hasn\'t been sent yet.'), findsOneWidget);

    server.unreachable = false;
    await syncAndPump(tester, r);
    expect(find.text('Synced with nas just now.'), findsOneWidget);
    expect(find.textContaining('been sent yet'), findsNothing);
  });

  testWidgets('a sync that brings answers from other devices updates the figures',
      (WidgetTester tester) async {
    await store.putAnswer(answer());
    server.addAnswer(answer(right: false, game: 'o').toJson());
    server.unreachable = true;
    final r = recorder(withServer: true);
    await pumpPage(tester, r);
    expect(find.text('1/1 right (100%)'), findsNWidgets(3));

    server.unreachable = false;
    await syncAndPump(tester, r);
    expect(find.text('1/2 right (50%)'), findsNWidgets(3));
  });

  testWidgets('the web says plainly when its server can\'t be reached',
      (WidgetTester tester) async {
    server.unreachable = true;
    final web = recorder(withServer: true, withStore: InMemoryHistoryStore(keepsHistory: false));
    await pumpPage(tester, web);
    expect(find.text('The history is on nas, which can\'t be reached right now.'),
        findsOneWidget);

    server.unreachable = false;
    server.addAnswer(answer().toJson());
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('All time'), findsOneWidget);
    expect(find.text('1/1 right (100%)'), findsWidgets);
  });

  testWidgets('the web asks for the token when its server wants one',
      (WidgetTester tester) async {
    server.token = 's3cret';
    final web = recorder(withServer: true, credentials: ApiCredentials(),
        withStore: InMemoryHistoryStore(keepsHistory: false));
    await pumpPage(tester, web);
    expect(find.textContaining('nas needs the access token'), findsOneWidget);
  });

  testWidgets('a game without dollars shows none', (WidgetTester tester) async {
    await store.putGame(game(dollars: 0, valued: 0, answered: 5, right: 4, best: 3));
    await pumpPage(tester, recorder());
    expect(find.text('4/5 right · best streak 3'), findsOneWidget);
  });
}
