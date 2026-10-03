import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quizapp/controller/question_repository.dart';
import 'package:quizapp/data/hidden_question_store.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/main.dart';
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

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(QuizApp(
        repository: QuestionRepository(source: source, hiddenStore: hidden)));
    await tester.pump();
  }

  testWidgets('Shows a question and toggles its answer', (WidgetTester tester) async {
    await pumpApp(tester);

    expect(find.text('Random Trivia Question'), findsOneWidget);
    expect(find.text('CATEGORY 1'), findsOneWidget);
    expect(find.text('CLUE 1'), findsOneWidget);

    await tester.tap(find.byType(QuestionAnswerWidget));
    await tester.pump();
    expect(find.text('RESPONSE 1'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(find.text('CLUE 2'), findsOneWidget);
  });

  testWidgets('Page still builds when the source is down', (WidgetTester tester) async {
    source.error = const SourceUnavailable('down');
    await pumpApp(tester);

    expect(find.text('Report Question'), findsOneWidget);
    expect(find.byType(QuestionCategoryWidget), findsOneWidget);
    expect(find.byType(QuestionAnswerWidget), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
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

  testWidgets('Report dialog can be cancelled', (WidgetTester tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('Report Question'));
    await tester.pumpAndSettle();
    expect(find.text('Are you sure you want to report this question as invalid?'),
        findsOneWidget);

    await tester.tap(find.text('No'));
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing);
    expect(hidden.isHidden(fakeQuestion('1')), isFalse);
    expect(find.text('CLUE 1'), findsOneWidget);
  });

  testWidgets('Reporting hides the question and loads another', (WidgetTester tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('Report Question'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();

    expect(hidden.isHidden(fakeQuestion('1')), isTrue);
    expect(source.reported.map((q) => q.key), ['1']);
    expect(find.text('CLUE 2'), findsOneWidget);
  });
}
