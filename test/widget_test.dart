import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quizapp/controller/question_repository.dart';
import 'package:quizapp/data/fallback_question_source.dart';
import 'package:quizapp/data/filter_store.dart';
import 'package:quizapp/data/hidden_question_store.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/data/token_store.dart';
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

  group('access token', () {
    late ApiCredentials credentials;
    late InMemoryTokenStore tokens;

    Future<void> pumpGuarded(WidgetTester tester) async {
      credentials = ApiCredentials();
      tokens = InMemoryTokenStore();
      await tester.pumpWidget(QuizApp(repository: QuestionRepository(
          source: TokenGuardedSource([fakeQuestion('1')],
              credentials: credentials, token: 's3cret'),
          hiddenStore: hidden, tokenStore: tokens, credentials: credentials)));
      await tester.pump();
    }

    testWidgets('Asks for the token and connects with it', (WidgetTester tester) async {
      await pumpGuarded(tester);
      expect(find.text('fake source needs an access token.'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasPrimaryFocus, isTrue);

      await tester.enterText(find.byType(TextField), 's3cret');
      await tester.tap(find.text('Connect'));
      await tester.pump();
      expect(find.text('CLUE 1'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(tokens.token, 's3cret');
      // The shortcuts work again without clicking the page first.
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(find.text('RESPONSE 1'), findsOneWidget);
    });

    testWidgets('Says when the token is rejected', (WidgetTester tester) async {
      await pumpGuarded(tester);
      await tester.enterText(find.byType(TextField), 'wrong');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('fake source rejected the access token.'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    });

    testWidgets('Ignores an empty token', (WidgetTester tester) async {
      await pumpGuarded(tester);
      await tester.tap(find.text('Connect'));
      await tester.pump();
      expect(tokens.token, isNull);
      expect(find.text('fake source needs an access token.'), findsOneWidget);
    });

    testWidgets('Without a token store, a rejected token just offers Retry',
        (WidgetTester tester) async {
      source.error = const Unauthorized('example.test rejected the access token.');
      await pumpApp(tester);
      expect(find.text('example.test rejected the access token.'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  testWidgets('Shows NoQuestionFound messages too', (WidgetTester tester) async {
    source.error = const NoQuestionFound('Every question tried has been hidden.');
    await pumpApp(tester);
    expect(find.text('Every question tried has been hidden.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('Labels Final Jeopardy, shows Daily Doubles at their board value, '
      'and shows the comment', (WidgetTester tester) async {
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
    expect(find.text('\$1,200'), findsOneWidget);
    expect(find.text('DAILY DOUBLE'), findsNothing);
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
    source = FakeQuestionSource([Question(sourceId: 'fake', key: '1',
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

  group('keyboard', () {
    testWidgets('Space and Enter flip the card; N and → load the next question',
        (WidgetTester tester) async {
      await pumpApp(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(find.text('RESPONSE 1'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('CLUE 1'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();
      expect(find.text('CLUE 2'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.text('CLUE 1'), findsOneWidget);
    });

    testWidgets('H opens the hide dialog', (WidgetTester tester) async {
      await pumpApp(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pumpAndSettle();
      expect(find.text('Hide this question?'), findsOneWidget);
      // Keys in the dialog don't reach the page.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.text('Hide this question?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('CLUE 1'), findsOneWidget);
    });

    testWidgets('F opens the filter sheet, and keys work again after it closes',
        (WidgetTester tester) async {
      source = FakeQuestionSource([fakeQuestion('1'), fakeQuestion('2')],
          supportedFilters: const {FilterKind.round, FilterKind.airDate});
      await pumpApp(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(find.text('Filter clues'), findsOneWidget);
      // Keys in the sheet don't reach the page.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();
      expect(find.text('CLUE 1'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Filter clues'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();
      expect(find.text('CLUE 2'), findsOneWidget);
    });

    testWidgets('F does nothing when the source can\'t filter', (WidgetTester tester) async {
      await pumpApp(tester);
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyF), isFalse);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('Typing a token doesn\'t trigger shortcuts', (WidgetTester tester) async {
      final credentials = ApiCredentials();
      final guarded = TokenGuardedSource([fakeQuestion('1'), fakeQuestion('2')],
          credentials: credentials, token: 'nh',
          supportedFilters: const {FilterKind.round, FilterKind.airDate});
      await tester.pumpWidget(QuizApp(repository: QuestionRepository(source: guarded,
          hiddenStore: hidden, tokenStore: InMemoryTokenStore(), credentials: credentials)));
      await tester.pump();
      await tester.showKeyboard(find.byType(TextField));
      // Unhandled, so in a browser the keys reach the text field.
      for (final key in [LogicalKeyboardKey.keyN, LogicalKeyboardKey.keyH,
          LogicalKeyboardKey.keyF, LogicalKeyboardKey.space, LogicalKeyboardKey.enter]) {
        expect(await tester.sendKeyEvent(key), isFalse, reason: '$key');
      }
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsNothing);
      expect(guarded.requests, 1);
      expect(find.text('fake source needs an access token.'), findsOneWidget);
    });
  });

  testWidgets('The board keeps its width in a wide window', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpApp(tester);
    final panel = tester.getRect(find.ancestor(
        of: find.byType(QuestionAnswerWidget), matching: find.byType(QuizDecorationWrapper)));
    expect(panel.width, 900);
    expect(panel.center.dx, 960);
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

  group('choices', () {
    final capital = fakeQuestion('1', answer: 'Paris',
        choices: ['Lyon', 'Paris', 'Nice', 'Lille'], difficulty: 'easy', value: null);
    final boils = fakeQuestion('2', answer: 'True', choices: ['True', 'False'],
        difficulty: 'medium', value: null);

    Finder choice(String text) => find.widgetWithText(TextButton, text);
    Color? background(WidgetTester tester, String text) => tester
        .widget<TextButton>(choice(text)).style!.backgroundColor!.resolve({});

    Future<void> pumpChoices(WidgetTester tester, {String? attribution}) async {
      source = FakeQuestionSource([capital, boils, fakeQuestion('3')],
          attribution: attribution);
      await pumpApp(tester);
    }

    testWidgets('shows a button per choice and the difficulty', (WidgetTester tester) async {
      await pumpChoices(tester);
      expect(find.byType(ChoiceListWidget), findsOneWidget);
      for (final text in ['Lyon', 'Paris', 'Nice', 'Lille']) {
        expect(choice(text), findsOneWidget);
      }
      expect(find.text('EASY'), findsOneWidget);

      // Without a keyboard there are no number labels.
      expect(find.text('1'), findsNothing);
    });

    testWidgets('a wrong pick turns red, the answer green, and the buttons stop',
        (WidgetTester tester) async {
      await pumpChoices(tester);
      final before = background(tester, 'Lyon');
      await tester.tap(choice('Nice'));
      await tester.pump();

      expect(background(tester, 'Nice'), isNot(before));
      expect(background(tester, 'Paris'), isNot(before));
      expect(background(tester, 'Paris'), isNot(background(tester, 'Nice')));
      expect(background(tester, 'Lyon'), before);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Paris\s+Right answer$')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Nice\s+Your pick, wrong$')), findsOneWidget);
      for (final text in ['Lyon', 'Paris', 'Nice', 'Lille']) {
        expect(tester.widget<TextButton>(choice(text)).onPressed, isNull);
      }
      // The card stays on the question.
      expect(find.text('CLUE 1'), findsOneWidget);
    });

    testWidgets('a right pick shows only the tick', (WidgetTester tester) async {
      await pumpChoices(tester);
      await tester.tap(choice('Paris'));
      await tester.pump();
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets('the next question starts unpicked; open questions have no choices',
        (WidgetTester tester) async {
      await pumpChoices(tester);
      await tester.tap(choice('Paris'));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      expect(choice('True'), findsOneWidget);
      expect(choice('False'), findsOneWidget);
      expect(find.text('MEDIUM'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);
      expect(tester.widget<TextButton>(choice('True')).onPressed, isNotNull);

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      expect(find.byType(ChoiceListWidget), findsNothing);
      expect(find.text('\$200'), findsOneWidget);
    });

    testWidgets('true or false sits side by side on a phone', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpChoices(tester);
      // Four choices stack in one column on a narrow screen.
      expect(tester.getTopLeft(choice('Lyon')).dx, tester.getTopLeft(choice('Paris')).dx);

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      expect(tester.getTopLeft(choice('True')).dy, tester.getTopLeft(choice('False')).dy);
      expect(tester.takeException(), isNull);
    });

    testWidgets('four choices sit in two columns on a wide screen',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpChoices(tester);
      expect(tester.getTopLeft(choice('Lyon')).dy, tester.getTopLeft(choice('Paris')).dy);
      expect(tester.getTopLeft(choice('Nice')).dy, tester.getTopLeft(choice('Lille')).dy);
      expect(tester.getTopLeft(choice('Nice')).dy,
          greaterThan(tester.getTopLeft(choice('Lyon')).dy));
    });

    testWidgets('long choices fit on a small screen', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final long = 'A choice that is much too long to fit on one line ' * 3;
      source = FakeQuestionSource([fakeQuestion('1', answer: long,
          choices: [long, 'B', 'C', 'D'])]);
      await pumpApp(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping the card still reveals the answer', (WidgetTester tester) async {
      await pumpChoices(tester);
      await tester.tap(find.byType(QuestionAnswerWidget));
      await tester.pump();
      expect(find.text('PARIS'), findsOneWidget);
      // Choosing is still possible.
      expect(tester.widget<TextButton>(choice('Lyon')).onPressed, isNotNull);
    });

    testWidgets('number keys pick a choice', (WidgetTester tester) async {
      await pumpChoices(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.pump();
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
      // Only the first pick counts.
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.digit2), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();
      // True or false has no third choice.
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.digit3), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pump();
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();
      // An open question has no choices.
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.digit1), isFalse);
    });

    testWidgets('number labels show with a keyboard', (WidgetTester tester) async {
      await pumpChoices(tester);
      for (final number in ['1', '2', '3', '4']) {
        expect(find.descendant(of: find.byType(ChoiceListWidget), matching: find.text(number)),
            findsOneWidget);
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('credits the source in the overlay and an About dialog',
        (WidgetTester tester) async {
      const credit = 'Questions from Open Trivia Database (opentdb.com), CC BY-SA 4.0';
      await pumpChoices(tester, attribution: credit);

      await tester.tap(find.byIcon(Icons.info));
      await tester.pump();
      expect(find.text(credit), findsOneWidget);
      await tester.tap(find.byIcon(Icons.info));
      await tester.pump();

      await tester.tap(find.byTooltip('About questions'));
      await tester.pumpAndSettle();
      expect(find.text('About questions'), findsOneWidget);
      expect(find.text(credit), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text(credit), findsNothing);
    });

    testWidgets('no About button when the source needs no credit',
        (WidgetTester tester) async {
      await pumpChoices(tester);
      expect(find.byTooltip('About questions'), findsNothing);
      await tester.tap(find.byIcon(Icons.info));
      await tester.pump();
      expect(find.byType(QuestionOverlay), findsOneWidget);
    });
  });

  group('filters', () {
    const all = {FilterKind.round, FilterKind.airDate, FilterKind.boardRow};
    final nineties = QuestionFilter(from: DateTime(1990), to: DateTime(1999, 12, 31));
    late InMemoryFilterStore store;

    setUp(() {
      source = FakeQuestionSource([fakeQuestion('1'), fakeQuestion('2')],
          supportedFilters: all);
      store = InMemoryFilterStore();
    });

    Future<void> pumpFiltered(WidgetTester tester) async {
      await tester.pumpWidget(QuizApp(repository: QuestionRepository(
          source: source, hiddenStore: hidden, filterStore: store)));
      await tester.pump();
    }

    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.byIcon(store.filter.isAny
          ? Icons.filter_alt_outlined : Icons.filter_alt));
      await tester.pumpAndSettle();
    }

    Future<void> apply(WidgetTester tester) async {
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
    }

    FilterChip chip(WidgetTester tester, String label) =>
        tester.widget<FilterChip>(find.widgetWithText(FilterChip, label));

    Future<void> tapChip(WidgetTester tester, String label) async {
      final finder = find.widgetWithText(FilterChip, label);
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pump();
    }

    testWidgets('no button when the source supports no filters', (WidgetTester tester) async {
      source = FakeQuestionSource([fakeQuestion('1')]);
      await pumpFiltered(tester);
      expect(find.byIcon(Icons.filter_alt_outlined), findsNothing);
      expect(find.byIcon(Icons.filter_alt), findsNothing);
    });

    testWidgets('applying a filter saves it and loads a matching question',
        (WidgetTester tester) async {
      await pumpFiltered(tester);
      expect(find.text('CLUE 1'), findsOneWidget);
      expect(find.byTooltip('Filter clues'), findsOneWidget);

      await openSheet(tester);
      expect(find.text('Any year'), findsOneWidget);
      await tester.tap(find.text('Final Jeopardy!'));
      await tester.pump();
      await apply(tester);

      expect(store.filter, const QuestionFilter(rounds: {1, 2}));
      expect(source.lastFilter, const QuestionFilter(rounds: {1, 2}));
      expect(find.text('CLUE 2'), findsOneWidget);
      expect(find.byIcon(Icons.filter_alt), findsOneWidget);
      expect(find.byTooltip('Filters: Jeopardy!, Double Jeopardy!'), findsOneWidget);
    });

    testWidgets('applying the same filter changes nothing', (WidgetTester tester) async {
      store.filter = nineties;
      await pumpFiltered(tester);
      expect(source.lastFilter, nineties);
      expect(find.byTooltip('Filters: 1990–1999'), findsOneWidget);
      await openSheet(tester);
      expect(find.text('1990–1999'), findsOneWidget);
      await apply(tester);
      expect(find.text('CLUE 1'), findsOneWidget);
    });

    testWidgets('closing the sheet without Apply changes nothing', (WidgetTester tester) async {
      await pumpFiltered(tester);
      await openSheet(tester);
      await tester.tap(find.text('Final Jeopardy!'));
      await tester.pump();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(store.filter, QuestionFilter.any);
      expect(find.text('CLUE 1'), findsOneWidget);
    });

    testWidgets('the last round can\'t be turned off', (WidgetTester tester) async {
      await pumpFiltered(tester);
      await openSheet(tester);
      await tester.tap(find.text('Jeopardy!'));
      await tester.tap(find.text('Double Jeopardy!'));
      await tester.pump();
      expect(chip(tester, 'Final Jeopardy!').onSelected, isNull);
      expect(chip(tester, 'Jeopardy!').onSelected, isNotNull);
      await apply(tester);
      expect(store.filter, const QuestionFilter(rounds: {3}));
    });

    testWidgets('Reset goes back to any filter', (WidgetTester tester) async {
      store.filter = QuestionFilter(rounds: const {3}, from: DateTime(2001));
      await pumpFiltered(tester);
      await openSheet(tester);
      expect(chip(tester, 'Jeopardy!').selected, isFalse);
      expect(find.text('2001–${DateTime.now().year}'), findsOneWidget);
      await tester.tap(find.text('Reset'));
      await tester.pump();
      expect(chip(tester, 'Jeopardy!').selected, isTrue);
      expect(find.text('Any year'), findsOneWidget);
      await apply(tester);
      expect(store.filter, QuestionFilter.any);
      expect(find.byIcon(Icons.filter_alt_outlined), findsOneWidget);
    });

    testWidgets('the sheet fits on a small screen', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpFiltered(tester);
      await openSheet(tester);
      expect(tester.takeException(), isNull);
      await apply(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('choosing board rows', (WidgetTester tester) async {
      await pumpFiltered(tester);
      await openSheet(tester);
      expect(find.text('Difficulty'), findsOneWidget);
      for (final row in ['1', '2', '3']) {
        await tapChip(tester, row);
      }
      await apply(tester);
      expect(store.filter, const QuestionFilter(boardRows: {4, 5}));
      expect(source.lastFilter, const QuestionFilter(boardRows: {4, 5}));
      expect(find.byTooltip('Filters: rows 4–5'), findsOneWidget);
    });

    testWidgets('the last board row can\'t be turned off', (WidgetTester tester) async {
      store.filter = const QuestionFilter(boardRows: {5});
      await pumpFiltered(tester);
      await openSheet(tester);
      expect(chip(tester, '5').onSelected, isNull);
      expect(chip(tester, '4').onSelected, isNotNull);
    });

    testWidgets('board rows are off when only Final Jeopardy is chosen',
        (WidgetTester tester) async {
      store.filter = const QuestionFilter(boardRows: {4, 5});
      await pumpFiltered(tester);
      await openSheet(tester);
      await tapChip(tester, 'Jeopardy!');
      await tapChip(tester, 'Double Jeopardy!');
      expect(find.text('Final Jeopardy has no board row.'), findsOneWidget);
      for (final row in ['1', '2', '3', '4', '5']) {
        expect(chip(tester, row).onSelected, isNull, reason: row);
      }
      await apply(tester);
      expect(store.filter, const QuestionFilter(rounds: {3}));
    });

    group('for general trivia', () {
      const triviaFilters = {FilterKind.category, FilterKind.difficulty};
      const categories = ['Art', 'Geography', 'History'];

      setUp(() {
        source = FakeQuestionSource([
          fakeQuestion('1', category: 'Art', difficulty: 'easy', value: null),
          fakeQuestion('2', category: 'History', difficulty: 'hard', value: null),
        ], supportedFilters: triviaFilters, categories: categories);
      });

      testWidgets('offers categories and difficulty, not rounds or years',
          (WidgetTester tester) async {
        await pumpFiltered(tester);
        expect(find.byTooltip('Filter questions'), findsOneWidget);
        await openSheet(tester);
        expect(find.text('Filter questions'), findsOneWidget);
        expect(find.text('Rounds'), findsNothing);
        expect(find.text('Years'), findsNothing);
        for (final name in [...categories, 'Easy', 'Medium', 'Hard']) {
          expect(find.widgetWithText(FilterChip, name), findsOneWidget, reason: name);
        }
        expect(find.text('Every category. Choose some to play only those.'), findsOneWidget);
        // No category chosen means every category, so none is selected.
        expect(chip(tester, 'Art').selected, isFalse);
        expect(chip(tester, 'Hard').selected, isTrue);
      });

      testWidgets('choosing categories and a difficulty', (WidgetTester tester) async {
        await pumpFiltered(tester);
        await openSheet(tester);
        await tapChip(tester, 'History');
        await tapChip(tester, 'Art');
        expect(find.text('2 chosen.'), findsOneWidget);
        await tapChip(tester, 'Easy');
        await tapChip(tester, 'Medium');
        // The last difficulty can't be turned off.
        expect(chip(tester, 'Hard').onSelected, isNull);
        await apply(tester);

        const chosen = QuestionFilter(categories: {'Art', 'History'}, difficulties: {'hard'});
        expect(store.filter, chosen);
        expect(source.lastFilter, chosen);
        expect(find.byTooltip('Filters: Art, History, Hard'), findsOneWidget);

        // Every category can be turned off again.
        await openSheet(tester);
        await tapChip(tester, 'Art');
        await tapChip(tester, 'History');
        await tapChip(tester, 'Easy');
        await apply(tester);
        expect(store.filter, const QuestionFilter(difficulties: {'easy', 'hard'}));
      });

      testWidgets('many categories are counted', (WidgetTester tester) async {
        store.filter = const QuestionFilter(categories: {'Art', 'Geography', 'History'});
        await pumpFiltered(tester);
        expect(find.byTooltip('Filters: 3 categories'), findsOneWidget);
      });

      testWidgets('says when the categories can\'t be loaded', (WidgetTester tester) async {
        source.categoriesError = const SourceUnavailable('offline');
        await pumpFiltered(tester);
        await openSheet(tester);
        expect(find.text("The categories couldn't be loaded."), findsOneWidget);
        await tapChip(tester, 'Easy');
        await apply(tester);
        expect(store.filter, const QuestionFilter(difficulties: {'medium', 'hard'}));
      });
    });

    testWidgets('the sheet only offers what the source supports', (WidgetTester tester) async {
      source = FakeQuestionSource([fakeQuestion('1')], supportedFilters: {FilterKind.airDate});
      await pumpFiltered(tester);
      await openSheet(tester);
      expect(find.text('Years'), findsOneWidget);
      expect(find.byType(FilterChip), findsNothing);
      expect(find.text('Difficulty'), findsNothing);
    });

    testWidgets('with no match, offers to change or clear the filters',
        (WidgetTester tester) async {
      store.filter = nineties;
      source.error = const NoQuestionFound();
      await pumpFiltered(tester);
      expect(find.text('No clues match your filters.'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);

      await tester.tap(find.text('Change filters'));
      await tester.pumpAndSettle();
      expect(find.text('Filter clues'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      source.error = null;
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(store.filter, QuestionFilter.any);
      expect(find.text('CLUE 1'), findsOneWidget);
    });
  });
}
