import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quizapp/main.dart';
import 'package:quizapp/ui/quiz_question/quiz_ui_library.dart';

void main() {
  // Widget tests answer every HTTP request with a 400, so no question loads;
  // the page must still build and stay usable.
  testWidgets('Quiz page builds without a question', (WidgetTester tester) async {
    await tester.pumpWidget(const QuizApp());
    await tester.pump();

    expect(find.text('Random Trivia Question'), findsOneWidget);
    expect(find.text('Report Question'), findsOneWidget);
    expect(find.byType(QuestionCategoryWidget), findsOneWidget);
    expect(find.byType(QuestionAnswerWidget), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('Info button toggles the raw data overlay', (WidgetTester tester) async {
    await tester.pumpWidget(const QuizApp());
    expect(find.byType(QuestionOverlay), findsNothing);

    await tester.tap(find.byIcon(Icons.info));
    await tester.pump();
    expect(find.byType(QuestionOverlay), findsOneWidget);

    await tester.tap(find.byIcon(Icons.info));
    await tester.pump();
    expect(find.byType(QuestionOverlay), findsNothing);
  });

  testWidgets('Report dialog can be cancelled', (WidgetTester tester) async {
    await tester.pumpWidget(const QuizApp());

    await tester.tap(find.text('Report Question'));
    await tester.pumpAndSettle();
    expect(find.text('Are you sure you want to report this question as invalid?'),
        findsOneWidget);

    await tester.tap(find.text('No'));
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing);
  });
}
