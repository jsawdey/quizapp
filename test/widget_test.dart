import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quizapp/controller/question_repository.dart';
import 'package:quizapp/data/fallback_question_source.dart';
import 'package:quizapp/data/hidden_question_store.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/main.dart';
import 'package:quizapp/model/question.dart';
import 'package:quizapp/ui/quiz_question/quiz_ui_library.dart';

import 'support/fakes.dart';

void main() {
  late FakeQuestionSource source;
  late InMemoryHiddenQuestionStore hidden;

  setUp(() {
    source = FakeQuestionSource([fakeQuestion('1'), fakeQuestion('2')],
        supportsRemoteReport: true);
    hidden = InMemoryHiddenQuestionStore();
  });

  Future<void> pumpApp(WidgetTester tester, {QuestionSource? withSource}) async {
    await tester.pumpWidget(QuizApp(repository: QuestionRepository(
        source: withSource ?? source, hiddenStore: hidden)));
    await tester.pump();
  }

  Finder hideButton() => find.widgetWithText(TextButton, 'Hide Question');

  testWidgets('Shows a question and toggles its answer', (WidgetTester tester) async {
    await pumpApp(tester);

    expect(find.text('Random Trivia Question'), findsOneWidget);
    expect(find.text('CATEGORY 1'), findsOneWidget);
    expect(find.text('\$200'), findsOneWidget);
    expect(find.text('CLUE 1'), findsOneWidget);

    await tester.tap(find.byType(QuestionAnswerWidget));
    await tester.pump();
    expect(find.text('RESPONSE 1'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(find.text('CLUE 2'), findsOneWidget);
  });

  testWidgets('Shows a loading indicator until the first question arrives',
      (WidgetTester tester) async {
    final gate = Completer<void>();
    source.gate = gate.future;
    await pumpApp(tester);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Loading questions…'), findsOneWidget);
    expect(tester.widget<TextButton>(hideButton()).onPressed, isNull);
    expect(tester.widget<FloatingActionButton>(find.byType(FloatingActionButton)).onPressed,
        isNull);

    gate.complete();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('CLUE 1'), findsOneWidget);
    expect(tester.widget<TextButton>(hideButton()).onPressed, isNotNull);
  });

  testWidgets('Shows why a question could not load, with Retry', (WidgetTester tester) async {
    source.error = const SourceUnavailable('No clue database is bundled with this build.');
    await pumpApp(tester);

    expect(find.text('No clue database is bundled with this build.'), findsOneWidget);
    expect(tester.widget<TextButton>(hideButton()).onPressed, isNull);

    source.error = null;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.text('Retry'), findsNothing);
    expect(find.text('CLUE 1'), findsOneWidget);
  });

  testWidgets('Shows NoQuestionFound messages too', (WidgetTester tester) async {
    source.error = const NoQuestionFound('Every question tried has been hidden.');
    await pumpApp(tester);
    expect(find.text('Every question tried has been hidden.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('Labels Final Jeopardy and Daily Doubles, and shows the comment',
      (WidgetTester tester) async {
    source = FakeQuestionSource([
      fakeQuestion('1', round: 3, value: null, categoryComment: '(Alex: Think big.)'),
      fakeQuestion('2', round: 2, value: 1200, dailyDoubleWager: 2000),
      fakeQuestion('3', round: 2, value: 1600),
    ]);
    await pumpApp(tester);
    expect(find.text('FINAL JEOPARDY'), findsOneWidget);
    expect(find.text('(Alex: Think big.)'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(find.text('DAILY DOUBLE'), findsOneWidget);
    expect(find.text('(Alex: Think big.)'), findsNothing);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(find.text('\$1,600'), findsOneWidget);
  });

  testWidgets('Long text fits on a small screen', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    source = FakeQuestionSource([fakeQuestion('1', round: 2, value: 2000,
        category: 'A VERY LONG CATEGORY NAME THAT GOES ON AND ON AND ON',
        categoryComment: '(Alex: ${'This comment is far too long to fit. ' * 6})')]);
    await pumpApp(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('\$2,000'), findsOneWidget);
  });

  testWidgets('A long clue is scaled to stay inside its panel', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    source = FakeQuestionSource([JeopardyQuestion(sourceId: 'fake', key: '1',
        question: 'A clue that keeps going and going ' * 8, answer: 'yes',
        category: 'LONG CLUES')]);
    await pumpApp(tester);

    final panel = tester.getRect(find.ancestor(
        of: find.byType(QuestionAnswerWidget), matching: find.byType(QuizDecorationWrapper)));
    final text = find.descendant(
        of: find.byType(QuestionAnswerWidget), matching: find.byType(Text));
    final box = tester.renderObject<RenderBox>(text);
    final topLeft = box.localToGlobal(Offset.zero);
    final bottomRight = box.localToGlobal(box.size.bottomRight(Offset.zero));
    expect(panel.contains(topLeft), isTrue);
    expect(panel.contains(bottomRight - const Offset(1, 1)), isTrue);
    // The text was given all the height it needs, rather than being clipped
    // to the panel.
    expect(box.getMinIntrinsicHeight(box.size.width), lessThanOrEqualTo(box.size.height));
  });

  testWidgets('Info button toggles the raw data overlay', (WidgetTester tester) async {
    await pumpApp(tester);
    expect(find.byType(QuestionOverlay), findsNothing);

    await tester.tap(find.byIcon(Icons.info));
    await tester.pump();
    expect(find.byType(QuestionOverlay), findsOneWidget);
    expect(find.text('key: 1'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.info));
    await tester.pump();
    expect(find.byType(QuestionOverlay), findsNothing);
  });

  testWidgets('Hide dialog can be cancelled', (WidgetTester tester) async {
    await pumpApp(tester);

    await tester.tap(hideButton());
    await tester.pumpAndSettle();
    expect(find.text('Hide this question?'), findsOneWidget);
    expect(find.textContaining('reported to fake source'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing);
    expect(hidden.isHidden(fakeQuestion('1')), isFalse);
    expect(find.text('CLUE 1'), findsOneWidget);
  });

  testWidgets('Hiding a question reports it and loads another', (WidgetTester tester) async {
    await pumpApp(tester);

    await tester.tap(hideButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide'));
    await tester.pumpAndSettle();

    expect(hidden.isHidden(fakeQuestion('1')), isTrue);
    expect(source.reported.map((q) => q.key), ['1']);
    expect(find.text('CLUE 2'), findsOneWidget);
  });

  testWidgets('The hide dialog only mentions reporting when it will happen',
      (WidgetTester tester) async {
    source = FakeQuestionSource([fakeQuestion('1')]);
    await pumpApp(tester);

    await tester.tap(hideButton());
    await tester.pumpAndSettle();
    expect(find.text("You won't see it again."), findsOneWidget);
    expect(find.textContaining('reported'), findsNothing);
  });

  testWidgets('Shows an offline icon while using the fallback', (WidgetTester tester) async {
    final primary = FakeQuestionSource([fakeQuestion('api', sourceId: 'api')],
        supportsRemoteReport: true)
      ..error = const SourceUnavailable('offline');
    final fallback = FakeQuestionSource([fakeQuestion('local', sourceId: 'local')]);
    await pumpApp(tester,
        withSource: FallbackQuestionSource(primary: primary, fallback: fallback));
    expect(find.text('CLUE LOCAL'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off), findsOneWidget);

    // A fallback clue isn't reported anywhere, so the dialog doesn't say so.
    await tester.tap(hideButton());
    await tester.pumpAndSettle();
    expect(find.textContaining('reported'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('No offline icon while the primary works', (WidgetTester tester) async {
    final primary = FakeQuestionSource([fakeQuestion('api', sourceId: 'api')]);
    final fallback = FakeQuestionSource([fakeQuestion('local', sourceId: 'local')]);
    await pumpApp(tester,
        withSource: FallbackQuestionSource(primary: primary, fallback: fallback));
    expect(find.text('CLUE API'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off), findsNothing);
  });
}
