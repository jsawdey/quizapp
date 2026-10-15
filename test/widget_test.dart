import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quizapp/config/source_choice.dart';
import 'package:quizapp/controller/question_repository.dart';
import 'package:quizapp/controller/score_keeper.dart';
import 'package:quizapp/data/fallback_question_source.dart';
import 'package:quizapp/data/filter_store.dart';
import 'package:quizapp/data/hidden_question_store.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/data/score_store.dart';
import 'package:quizapp/data/token_store.dart';
import 'package:quizapp/main.dart';
import 'package:quizapp/model/question.dart';
import 'package:quizapp/model/score.dart';
import 'package:quizapp/ui/quiz_question/quiz_ui_library.dart';
import 'package:quizapp/ui/score_line_widget.dart';

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

    expect(find.text('Trivia'), findsOneWidget);
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

  group('choosing the source', () {
    late InMemorySourceChoiceStore choice;
    late FakeQuestionSource clues;
    late FakeQuestionSource trivia;
    late SourceChooser sources;

    setUp(() {
      clues = FakeQuestionSource([fakeQuestion('1')]);
      trivia = FakeQuestionSource([fakeQuestion('t', answer: 'Bern',
          choices: ['Bern', 'Wien'], value: null, difficulty: 'easy')]);
      choice = InMemorySourceChoiceStore();
      sources = SourceChooser([
        SourceOption(id: 'local:clues', label: 'Jeopardy! clues', detail: 'On this device',
            create: () => clues),
        SourceOption(id: 'opentdb', label: 'Open Trivia Database', detail: 'Online trivia',
            create: () => trivia),
      ], store: choice);
    });

    Future<void> pumpWithSources(WidgetTester tester) async {
      await tester.pumpWidget(QuizApp(sources: sources,
          repository: QuestionRepository(source: sources.current.create(), hiddenStore: hidden)));
      await tester.pump();
    }

    testWidgets('switches to the chosen source and remembers it', (WidgetTester tester) async {
      await pumpWithSources(tester);
      expect(find.text('CLUE 1'), findsOneWidget);
      expect(find.byTooltip('Questions from: Jeopardy! clues'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.swap_horiz));
      await tester.pumpAndSettle();
      expect(find.text('Questions from'), findsOneWidget);
      expect(find.text('Online trivia'), findsOneWidget);
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Jeopardy! clues')).selected,
          isTrue);

      await tester.tap(find.text('Open Trivia Database'));
      await tester.pumpAndSettle();
      expect(find.text('CLUE T'), findsOneWidget);
      expect(find.byType(ChoiceListWidget), findsOneWidget);
      expect(find.text('EASY'), findsOneWidget);
      expect(choice.id, 'opentdb');
      expect(clues.closes, 1);
      expect(find.byTooltip('Questions from: Open Trivia Database'), findsOneWidget);
    });

    testWidgets('closing the dialog changes nothing', (WidgetTester tester) async {
      await pumpWithSources(tester);
      await tester.tap(find.byIcon(Icons.swap_horiz));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('CLUE 1'), findsOneWidget);
      expect(choice.id, isNull);
      expect(clues.closes, 0);
    });

    testWidgets('can switch away from a source that fails', (WidgetTester tester) async {
      clues.error = const SourceUnavailable('No clue database is bundled with this build.');
      await pumpWithSources(tester);
      expect(find.text('No clue database is bundled with this build.'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.swap_horiz));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Trivia Database'));
      await tester.pumpAndSettle();
      expect(find.text('CLUE T'), findsOneWidget);
    });

    testWidgets('offers the server\'s other databases once it has said what it holds',
        (WidgetTester tester) async {
      final nas = Uri.parse('http://nas:8080/');
      final datasets = [
        ServerDataset(name: 'clues', kind: 'clues', url: nas),
        ServerDataset(name: 'trivia', kind: 'trivia', url: nas.resolve('trivia/')),
      ];
      clues.serverDatasets = datasets;
      final saved = InMemoryServerDatasetStore();
      final created = <Uri>[];
      sources = SourceChooser([
        SourceOption(id: SourceChooser.configuredId, label: 'nas',
            detail: 'Your question server', create: () => clues),
        SourceOption(id: 'opentdb', label: 'Open Trivia Database', detail: 'Online trivia',
            create: () => FakeQuestionSource([fakeQuestion('o')])),
      ], store: choice, server: ConfiguredServer(url: nas,
          detail: 'Your question server (nas)', configuredDetail: 'Your question server (nas)',
          store: saved, create: (dataset) {
            created.add(dataset.url);
            return trivia;
          }));
      await pumpWithSources(tester);
      expect(find.text('CLUE 1'), findsOneWidget);
      expect(saved.datasets, datasets);

      await tester.tap(find.byIcon(Icons.swap_horiz));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Jeopardy! clues'), findsOneWidget);
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Jeopardy! clues')).selected,
          isTrue);
      await tester.tap(find.widgetWithText(ListTile, 'Trivia'));
      await tester.pumpAndSettle();
      expect(created, [nas.resolve('trivia/')]);
      expect(find.text('CLUE T'), findsOneWidget);
      expect(choice.id, 'server:trivia');
      expect(find.byTooltip('Questions from: Trivia'), findsOneWidget);
    });

    testWidgets('no button with nothing to choose, or while loading',
        (WidgetTester tester) async {
      final gate = Completer<void>();
      clues.gate = gate.future;
      await pumpWithSources(tester);
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.swap_horiz))
          .onPressed, isNull);
      gate.complete();
      await tester.pump();

      await pumpApp(tester);
      expect(find.byIcon(Icons.swap_horiz), findsNothing);
    });
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

  group('score', () {
    final capital = fakeQuestion('1', answer: 'Paris',
        choices: ['Lyon', 'Paris', 'Nice', 'Lille'], value: null);
    final boils = fakeQuestion('2', answer: 'True', choices: ['True', 'False'], value: null);
    // Two right in a row, so there's a streak to break.
    const onARoll = Score(answered: 2, right: 2, streak: 2, best: 2);
    late InMemoryScoreStore scores;
    late ScoreKeeper keeper;

    setUp(() {
      source = FakeQuestionSource([capital, boils, fakeQuestion('3')],
          supportsRemoteReport: true);
      scores = InMemoryScoreStore();
      keeper = ScoreKeeper(store: scores, now: () => DateTime(2026, 10, 11, 20));
    });

    Future<void> pumpScored(WidgetTester tester,
        {QuestionRepository? repository, SourceChooser? sources}) async {
      await tester.pumpWidget(QuizApp(scoreKeeper: keeper, sources: sources,
          repository: repository ?? QuestionRepository(source: source, hiddenStore: hidden)));
      await tester.pump();
    }

    Finder choice(String text) => find.widgetWithText(TextButton, text);
    Finder scoreLine([String? text]) => text == null
        ? find.descendant(of: find.byType(ScoreLineWidget), matching: find.byType(Text))
        : find.descendant(of: find.byType(ScoreLineWidget), matching: find.text(text));

    Future<void> next(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
    }

    testWidgets('a pick counts, and the score line opens the score', (WidgetTester tester) async {
      await pumpScored(tester);
      // Nothing to show before the first result.
      expect(scoreLine(), findsNothing);

      await tester.tap(choice('Paris'));
      await tester.pump();
      expect(scoreLine('1/1 right · streak 1'), findsOneWidget);
      expect(scores.score.right, 1);

      await next(tester);
      await tester.tap(choice('False'));
      await tester.pump();
      expect(scoreLine('1/2 right · streak 0'), findsOneWidget);

      await tester.tap(scoreLine());
      await tester.pumpAndSettle();
      expect(find.text('Score'), findsOneWidget);
      expect(find.text('1 right out of 2 (50%)'), findsOneWidget);
      expect(find.text('Streak 0, best 1'), findsOneWidget);
      expect(find.text('Started Oct 11, 2026'), findsOneWidget);
      // No clue with a value has been scored.
      expect(find.textContaining('\$'), findsNothing);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Score'), findsNothing);
      expect(scoreLine('1/2 right · streak 0'), findsOneWidget);
    });

    testWidgets('a pick after peeking doesn\'t count, and moving on is a skip',
        (WidgetTester tester) async {
      keeper = ScoreKeeper(store: scores, initial: onARoll);
      await pumpScored(tester);
      await tester.tap(find.byType(QuestionAnswerWidget));
      await tester.pump();
      // Flipping back doesn't undo the peek.
      await tester.tap(find.byType(QuestionAnswerWidget));
      await tester.pump();
      await tester.tap(choice('Paris'));
      await tester.pump();
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(keeper.score, onARoll);

      await next(tester);
      expect(scoreLine('2/2 right · streak 0'), findsOneWidget);
      expect(scores.score.best, 2);
    });

    testWidgets('peeking after a pick still counts the pick', (WidgetTester tester) async {
      await pumpScored(tester);
      await tester.tap(choice('Paris'));
      await tester.pump();
      await tester.tap(find.byType(QuestionAnswerWidget));
      await tester.pump();
      expect(keeper.score.right, 1);
    });

    testWidgets('next without a result ends the streak, by button or key',
        (WidgetTester tester) async {
      keeper = ScoreKeeper(store: scores, initial: onARoll);
      await pumpScored(tester);
      await tester.tap(choice('Paris'));
      await tester.pump();
      // Answered, so moving on keeps the streak.
      await next(tester);
      expect(keeper.score.streak, 3);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();
      expect(keeper.score.streak, 0);
      expect(keeper.score.answered, 3);
    });

    testWidgets('hiding a question doesn\'t end the streak', (WidgetTester tester) async {
      keeper = ScoreKeeper(store: scores, initial: onARoll);
      await pumpScored(tester);
      await tester.tap(hideButton());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide'));
      await tester.pumpAndSettle();
      expect(find.text('CLUE 2'), findsOneWidget);
      expect(keeper.score, onARoll);
    });

    testWidgets('changing the filter doesn\'t end the streak', (WidgetTester tester) async {
      keeper = ScoreKeeper(store: scores, initial: onARoll);
      source.supportedFilters = {FilterKind.round};
      await pumpScored(tester, repository: QuestionRepository(source: source,
          hiddenStore: hidden, filterStore: InMemoryFilterStore()));
      await tester.tap(find.byIcon(Icons.filter_alt_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Final Jeopardy!'));
      await tester.pump();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.text('CLUE 2'), findsOneWidget);
      expect(keeper.score, onARoll);
    });

    testWidgets('switching source keeps the game and the streak', (WidgetTester tester) async {
      keeper = ScoreKeeper(store: scores, initial: onARoll);
      final sources = SourceChooser([
        SourceOption(id: 'local:clues', label: 'Jeopardy! clues', detail: 'On this device',
            create: () => FakeQuestionSource([fakeQuestion('c')])),
        SourceOption(id: 'opentdb', label: 'Open Trivia Database', detail: 'Online trivia',
            create: () => FakeQuestionSource([boils])),
      ], store: InMemorySourceChoiceStore());
      await pumpScored(tester, sources: sources,
          repository: QuestionRepository(source: sources.current.create(), hiddenStore: hidden));
      await tester.tap(find.byIcon(Icons.swap_horiz));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Trivia Database'));
      await tester.pumpAndSettle();
      expect(find.text('CLUE 2'), findsOneWidget);
      expect(keeper.score, onARoll);

      await tester.tap(choice('True'));
      await tester.pump();
      expect(scoreLine('3/3 right · streak 3'), findsOneWidget);
    });

    testWidgets('dollars show once a clue with a value is scored, with a minus sign when behind',
        (WidgetTester tester) async {
      source = FakeQuestionSource([fakeQuestion('1', round: 1, value: 400, answer: 'A',
          choices: ['A', 'B'])]);
      await pumpScored(tester);
      await tester.tap(choice('B'));
      await tester.pump();
      expect(scoreLine('0/1 right · streak 0 · −\$400'), findsOneWidget);
      expect(find.bySemanticsLabel('Score: 0 right out of 1, streak 0, minus 400 dollars'),
          findsOneWidget);

      await tester.tap(scoreLine());
      await tester.pumpAndSettle();
      expect(find.text('−\$400 from 1 clue'), findsOneWidget);
    });

    testWidgets('New game clears the score', (WidgetTester tester) async {
      await pumpScored(tester);
      await tester.tap(choice('Paris'));
      await tester.pump();
      await tester.tap(scoreLine());
      await tester.pumpAndSettle();
      await tester.tap(find.text('New game'));
      await tester.pumpAndSettle();
      expect(find.text('Score'), findsNothing);
      expect(scoreLine(), findsNothing);
      expect(scores.score, Score.empty);
    });

    testWidgets('a saved game shows from the start', (WidgetTester tester) async {
      keeper = await ScoreKeeper.load(InMemoryScoreStore(
          const Score(answered: 10, right: 7, streak: 3, best: 5, dollars: 4200, valued: 8)));
      await pumpScored(tester);
      expect(scoreLine('7/10 right · streak 3 · \$4,200'), findsOneWidget);
    });

    test('large numbers get thousands separators', () {
      const big = Score(answered: 1234, right: 987, streak: 45, best: 120,
          dollars: -123400, valued: 1100);
      expect(describeScore(big), '987/1,234 right · streak 45 · −\$123,400');
      expect(describeScoreAloud(big),
          'Score: 987 right out of 1,234, streak 45, minus 123,400 dollars');
    });

    testWidgets('a long score fits on a small screen', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      keeper = ScoreKeeper(store: scores, initial: const Score(answered: 12345,
          right: 1234, streak: 123, best: 123, dollars: -123400, valued: 9999));
      await pumpScored(tester);
      expect(scoreLine(), findsOneWidget);
      expect(hideButton(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    group('Got it and Missed it', () {
      final clue1 = fakeQuestion('1', round: 1, value: 200);
      final clue2 = fakeQuestion('2', round: 1, value: 400);
      Finder gotIt() => find.byKey(const ValueKey('got-it'));
      Finder missedIt() => find.byKey(const ValueKey('missed-it'));

      setUp(() => source = FakeQuestionSource([clue1, clue2]));

      Future<void> flip(WidgetTester tester) async {
        await tester.tap(find.byType(QuestionAnswerWidget));
        await tester.pump();
      }

      testWidgets('show once the response does, and a change of mind replaces the result',
          (WidgetTester tester) async {
        await pumpScored(tester);
        expect(find.text('Got it'), findsNothing);

        await flip(tester);
        expect(find.text('RESPONSE 1'), findsOneWidget);
        expect(find.text('Got it'), findsOneWidget);
        expect(find.text('Missed it'), findsOneWidget);
        expect(find.text('1'), findsNothing, reason: 'no number labels without a keyboard');

        await tester.tap(gotIt());
        await tester.pump();
        expect(scoreLine('1/1 right · streak 1 · \$200'), findsOneWidget);
        expect(find.byIcon(Icons.check), findsOneWidget);
        expect(find.byIcon(Icons.close), findsNothing);

        await tester.tap(missedIt());
        await tester.pump();
        expect(scoreLine('0/1 right · streak 0 · −\$200'), findsOneWidget);
        expect(find.byIcon(Icons.check), findsNothing);
        expect(find.byIcon(Icons.close), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp(r'^Missed it\s+Chosen$')), findsOneWidget);

        await tester.tap(gotIt());
        await tester.pump();
        expect(scoreLine('1/1 right · streak 1 · \$200'), findsOneWidget);
        expect(scores.score.answered, 1);

        // Flipping back keeps the result in view.
        await flip(tester);
        expect(find.text('CLUE 1'), findsOneWidget);
        expect(find.byIcon(Icons.check), findsOneWidget);

        // Answered, so moving on keeps the streak, and the next clue starts fresh.
        await next(tester);
        expect(find.text('CLUE 2'), findsOneWidget);
        expect(find.text('Got it'), findsNothing);
        expect(keeper.score.streak, 1);
      });

      testWidgets('the card keeps its size when the response shows', (WidgetTester tester) async {
        await pumpScored(tester);
        Size card() => tester.getSize(find.ancestor(of: find.byType(QuestionAnswerWidget),
            matching: find.byType(QuizDecorationWrapper)));
        final before = card();
        await flip(tester);
        expect(card(), before);
      });

      testWidgets('keys 1 and 2 answer once the response shows', (WidgetTester tester) async {
        await pumpScored(tester);
        expect(await tester.sendKeyEvent(LogicalKeyboardKey.digit1), isFalse);

        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(await tester.sendKeyEvent(LogicalKeyboardKey.digit3), isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
        await tester.pump();
        expect(keeper.score.right, 1);
        await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
        await tester.pump();
        expect(keeper.score.right, 0);
        expect(keeper.score.answered, 1);
      });

      testWidgets('are numbered, and the tooltip says so, with a keyboard',
          (WidgetTester tester) async {
        await pumpScored(tester);
        String tooltip() =>
            tester.widget<FloatingActionButton>(find.byType(FloatingActionButton)).tooltip!;
        expect(tooltip(), isNot(contains('1 or 2')));
        await flip(tester);
        expect(find.descendant(of: find.byType(SelfReportWidget), matching: find.text('1')),
            findsOneWidget);
        expect(find.descendant(of: find.byType(SelfReportWidget), matching: find.text('2')),
            findsOneWidget);
        expect(tooltip(), contains('; 1 or 2 says whether you got it.'));
      }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

      testWidgets('don\'t count while the next question loads', (WidgetTester tester) async {
        await pumpScored(tester);
        await flip(tester);
        final gate = Completer<void>();
        source.gate = gate.future;
        await next(tester);
        await tester.tap(gotIt());
        await tester.pump();
        expect(keeper.score.answered, 0);
        gate.complete();
        await tester.pump();
        expect(find.text('CLUE 2'), findsOneWidget);
      });

      testWidgets('aren\'t offered for multiple choice', (WidgetTester tester) async {
        source = FakeQuestionSource([capital]);
        await pumpScored(tester);
        await flip(tester);
        expect(find.text('PARIS'), findsOneWidget);
        expect(find.byType(SelfReportWidget), findsNothing);
      });

      testWidgets('aren\'t offered without a keeper', (WidgetTester tester) async {
        await pumpApp(tester);
        await flip(tester);
        expect(find.text('RESPONSE 1'), findsOneWidget);
        expect(find.byType(SelfReportWidget), findsNothing);
      });

      testWidgets('fit on a small screen', (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await pumpScored(tester);
        await flip(tester);
        await tester.tap(missedIt());
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    });

    testWidgets('Hide Question stays clear of the floating button', (WidgetTester tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1.0;
      for (final width in [360.0, 1280.0]) {
        tester.view.physicalSize = Size(width, 740);
        keeper = ScoreKeeper(store: scores, initial: onARoll);
        await pumpScored(tester);
        final hide = tester.getRect(hideButton());
        final button = tester.getRect(find.byType(FloatingActionButton));
        expect(hide.overlaps(button), isFalse, reason: 'at $width wide');
        expect(tester.getRect(scoreLine()).overlaps(hide), isFalse, reason: 'at $width wide');
      }
      // In a wide window the button is beside the board, so Hide Question
      // keeps to the board's edge.
      final board = tester.getRect(find.byType(ChoiceListWidget));
      expect(tester.getRect(hideButton()).right, closeTo(board.right - 4.0, 8.0));
    });

    testWidgets('without a keeper there is no score', (WidgetTester tester) async {
      await pumpApp(tester);
      await tester.tap(choice('Paris'));
      await tester.pump();
      expect(find.byType(ScoreLineWidget), findsNothing);
    });
  });
}
