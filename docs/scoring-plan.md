# Plan: Score keeping ("did you get it?")

The [filters](filters-plan.md) and [general trivia](general-trivia-plan.md)
plans are done, and so is most of "runtime backend settings": the ⇄ button
switches sources in the app. That leaves the last candidate from the
[web UI plan's](web-ui-plan.md) §0 list: **score keeping**. It "makes it a
game, not a flash card." Like the features before it, it is UI work written
once for phones, desktop and the browser.

## 0. What a person can do

- **Multiple choice and true/false score themselves.** Picking a choice
  already marks it right or wrong; now the pick also counts.
- **Open questions ask "did you get it?"** Once the response is showing,
  two buttons appear under the card: **Got it** and **Missed it**. Tapping
  one counts the question. You can change your mind until the next question
  loads, since a mis-tap on a phone is easy.
- **Skipping breaks the streak.** Moving on to the next question without
  scoring this one doesn't count as right or wrong, but it sets the streak
  back to 0, so a streak means questions answered in a row. The app still
  works as a flash card for anyone who doesn't want a score: the score line
  just stays empty.
- **A score line** sits at the bottom of the board, next to Hide Question:
  `7/10 right · streak 3`, plus `$4,200` once the game has had a Jeopardy
  clue with a value. Tapping it opens the score dialog.
- **The score dialog** shows the breakdown (right out of answered, as a
  percentage; the dollar score and how many clues it covers; the current and
  best streak; when the game started) and a **New game** button that clears
  it.
- **The game is kept between launches**, like the filter, so a phone app
  that's been killed or a reloaded browser tab picks up where it was.
- **Keyboard:** once the response shows, 1 is Got it and 2 is Missed it,
  numbered on the buttons as choices are.

## 1. What the code already does

| Code | What scoring needs from it |
|---|---|
| `_QuizPageState._picked` and `_pick` (`lib/quiz_page.dart`) | The moment a multiple-choice question is answered. `_pick` already refuses a second pick, so a pick is final. |
| `ChoiceListWidget` (`lib/ui/quiz_question/`) | Already shows right and wrong. Its button style is reused for Got it / Missed it. |
| `_showAnswer` and `_toggleAnswer` | When the response is showing, which is when Got it / Missed it appear. |
| `_PickIntent` and the 1–4 shortcuts | Reused for Got it / Missed it, so no new keys. |
| `Question.value`, `isFinalJeopardy`, `dailyDoubleWager` | The dollar score (§2). Daily Doubles already show and store their board value, and a set `dailyDoubleWager` marks them. |
| `SharedPrefsFilterStore` (`lib/data/filter_store.dart`) | The pattern for keeping the game: JSON in shared_preferences, an in-memory version for tests, and a bad saved value read as empty instead of failing. shared_preferences works on every platform the app runs on, the web included. |
| The bottom row of `_buildQuestionBody` | Only holds Hide Question now, so it has room for the score line. |

Nothing in `lib/` tracks a score yet, and `QuestionRepository` doesn't need
to: it deals with fetching, hiding and filtering questions. Scoring goes in
its own controller (§3), so the repository and its tests stay as they are.

## 2. What counts, and how

**Right and answered.** Each scored question adds 1 to `answered`, and 1 to
`right` if it was got right. The percentage is `right / answered`.

**Streak.** Right answers in a row. A miss or a skip sets it to 0; `best`
keeps the highest it has reached.

**Skips.** A skip is moving on to the next question (the refresh button, N
or →) without having scored the one showing. That includes a
multiple-choice question you peeked at and then picked, since that pick
doesn't count (below). A skip changes only the streak: it isn't added to
`answered`, so the percentage is about questions you answered. Hiding a
question isn't a skip (you're removing a bad question, not avoiding a
hard one), and neither is a source switch or a filter change, which replace
the question rather than move past it.

**Dollars: the Coryat score.** For Jeopardy clues, the dollar line is the
Coryat score (described in J! Archive's help), the usual way fans score
themselves at home, with no wagering: a right response adds the clue's
value and a wrong one subtracts it. Daily Doubles count at their board value
(which is what the app already shows), and a wrong one subtracts nothing,
since a contestant can't pass on a Daily Double. Final Jeopardy counts as
right or wrong but adds and subtracts nothing. So a question only moves the
dollar score when it has a `value` above 0 and isn't Final Jeopardy, and a
Daily Double (`dailyDoubleWager` set) only moves it up. `valued` counts those
questions, so the dialog can say "from 8 clues", and the score line only
shows dollars when `valued > 0`. General trivia has no values, so a trivia
game shows no dollars at all.

**Peeking at a multiple-choice question.** Tapping the card shows the
response, so that a multiple-choice question can be played as a flash card.
If you look before picking, the pick doesn't count: the buttons still turn
green and red as now, but the score doesn't change. Counting a peek as a
miss would punish using the card as a flash card, which the app explicitly
allows.

**One question, one result.** A question is scored at most once each time
it's shown. If a source serves it again later (OpenTDB starts a new session
after about 5,300 questions; The Trivia API has no session at all), it can
be scored again. That's the same question asked twice, so it's fair.

**Hiding.** Hiding a question you've already scored keeps the result: you
answered it. Hiding one you haven't scored counts nothing and keeps the
streak.

**Switching source or filter** keeps the game. Its counts mean the same
thing whatever the questions are; dollars only ever come from Jeopardy
clues. Starting a new game is up to you.

## 3. Model and controller

**`lib/model/score.dart`**: an immutable value class.

```dart
class Score {
  final int answered, right, streak, best;
  final int dollars;   // Coryat; can go below 0
  final int valued;    // how many scored questions had a dollar value
  final DateTime? started;  // when the first question of this game was scored

  static const empty = Score();
  Score record(Question question, {required bool right, required DateTime now});
  Score skipped();
}
```

`record` and `skipped` return the new score, with the rules from §2 in one
place. It is plain Dart, so the arithmetic is unit tested without widgets.

**`lib/data/score_store.dart`**: `ScoreStore` with `read()` and
`write(Score)`, plus `InMemoryScoreStore` and `SharedPrefsScoreStore`.
These mirror `FilterStore`. The saved form is one JSON value under the key
`score`:

```json
{"answered":10,"right":7,"streak":3,"best":5,"dollars":4200,"valued":8,"started":"2026-10-11"}
```

A missing or unreadable value, or one whose counts can't go together (a
negative count, more right than answered, a streak above the best), is
read as `Score.empty`. Writing `Score.empty` removes the key.

**`lib/controller/score_keeper.dart`**: a `ChangeNotifier` that the page
listens to.

```dart
class ScoreKeeper extends ChangeNotifier {
  ScoreKeeper({required ScoreStore store, Score initial = Score.empty});
  static Future<ScoreKeeper> load(ScoreStore store);  // reads the saved game
  Score get score;
  void show(Question question);             // a new question is showing
  Future<void> record({required bool right});  // the result for it
  Future<void> skip();                      // moving on without a result
  Future<void> newGame();
}
```

- **The question showing.** The page calls `show` whenever it puts a new
  question up, however it got there (next, hide, source switch, filter).
  `record` and `skip` apply to that question. `skip` breaks the streak only
  if the question has no result; the page calls it on next, not on the
  other ways a question is replaced (§2).
- **Changing your mind** about Got it or Missed it works by keeping the
  score from before the first result for the question showing. A second
  `record` recomputes from that snapshot instead of adding again. Streak
  and best can't be undone by subtracting, so recomputing is the only
  correct way. `show` and `newGame` drop the snapshot, and it is never
  saved: after a relaunch the old question is gone anyway.
- **Saving** happens after every change. The score changes and listeners
  hear about it at once; the returned future completes when the save is
  done, so tests can wait for it and the page needn't. A failed save is
  only logged (as with the filter): the score still counts until the app
  closes.
- **Loading:** `main.dart` awaits `ScoreKeeper.load` before `runApp`, as it
  awaits `SourceChooser.load`, so the saved game is there before the first
  result can be recorded. A game that can't be read is logged and starts
  empty.

## 4. UI (`lib/quiz_page.dart`, `lib/ui/`)

`QuizPage` and `QuizApp` take an optional `ScoreKeeper? scoreKeeper`, as
they take `sources`. With none, the page looks and behaves exactly as now:
no score line and no Got it / Missed it. That keeps the existing widget tests
as they are, and `main.dart` always passes one.

**Page state.** `_QuizPageState` gains `bool? _gotIt` (the self-report for
the current open question) and `bool _peeked` (the response was shown before
a choice was picked). Both reset in `_loadQuestion`, next to `_picked`,
which also calls `scoreKeeper.show` with the new question.

- `_toggleAnswer` sets `_peeked` if there are choices and `_picked` is null.
- `_pick` calls `scoreKeeper.record(right: choice == current.answer)`
  unless `_peeked`.
- `_report(bool gotIt)` sets `_gotIt` and calls `record`. Calling it again
  with the other value is the change of mind from §3.
- The refresh button and the N / → shortcut call a new `_nextQuestion`,
  which calls `scoreKeeper.skip()` and then `_loadQuestion`. Hiding,
  switching source and applying a filter keep calling `_loadQuestion`
  directly, so they don't break the streak.

**Got it / Missed it** (`lib/ui/quiz_question/self_report_widget.dart`): two
buttons in one row, styled like `ChoiceListWidget`'s and numbered 1 and 2 on
a keyboard. The chosen one gets the green tick or red cross; the other stays
enabled, so you can switch. For open questions, the page keeps a slot for
them under the card at all times (flex 1, taking one from the card's 4) and
fills it only when `_showAnswer` is true. That way the card doesn't jump in
size when the response is revealed. Multiple-choice questions don't get the
slot, since their choices already answer the question.

**Shortcuts.** `_canPick` and the `_PickIntent` action get a second case:
an open question with the response showing, where index 0 is Got it and 1 is
Missed it. The floating button's tooltip adds "; 1 or 2 says whether you got
it" while that applies, as it adds "1–4 pick a choice" for choices now.

**Score line** (`lib/ui/score_line_widget.dart`): the bottom row of the
board becomes a `Row` with the score line on the left and Hide Question on
the right. Its text is white, like Hide Question's; empty before the first
result, then `7/10 right · streak 3 · $4,200`, scaled down with a
`FittedBox` if a narrow phone can't fit it. It is a button whose semantics
label reads out in full ("Score: 7 right out of 10, streak 3, 4,200
dollars"). Negative dollars show as `−$400`, using the same `NumberFormat`
as clue values.

**Score dialog** (`lib/ui/score_dialog.dart`): an `AlertDialog` titled
"Score", with one line per figure from §0, "Started Oct 11, 2026" from
`started`, and the actions **New game** and
**Close**. New game asks nothing further: opening the dialog and pressing
the button is already two deliberate steps, and the button only clears the
score, never hidden questions or the filter.

## 5. Tests

| File | Checks |
|---|---|
| `test/score_test.dart` | Right and wrong; streak and best; a skip resets the streak only; Coryat adds and subtracts the value; Final Jeopardy and trivia questions count without dollars; a Daily Double adds its board value when right and subtracts nothing when wrong; `started` set by the first result only |
| `test/score_store_test.dart` | JSON round trip; missing, malformed and inconsistent values read as `Score.empty`; writing empty removes the key |
| `test/score_keeper_test.dart` | `load` reads the saved game, or starts empty when it can't; records and saves; changing your mind from right to wrong and back gives the same score as recording once, streak and best included; `show` drops the snapshot; `skip` breaks the streak only without a result; `newGame`; a save that fails still counts; listeners hear every change |
| `test/widget_test.dart` | A pick updates the score line; peeking then picking leaves it unchanged; Got it / Missed it only after the response shows, and switching between them; keys 1 and 2; no score UI without a keeper; dialog figures and New game; next without a result breaks the streak, but hide, a source switch and a filter change don't; a game saved by one keeper is shown by a new one with the same store |

`test/support/fakes.dart` already makes questions with and without values,
rounds and choices, which covers every case in §2.

## 6. Suggested commit order

1. ~~**`Score`, `ScoreStore` and `ScoreKeeper`**, plus their tests. No UI;
   nothing calls them yet.~~ (done)
2. ~~**Multiple-choice scoring**: the score line, the dialog with New game,
   peeking, and `main.dart` creating the keeper, plus widget tests. This is
   the smallest change that turns trivia into a game, and it can be tried
   against OpenTDB on its own.~~ (done. Until commit 3, an open question
   can't be scored, so moving on from one is a skip.)
3. ~~**Got it / Missed it** for open questions, with the reserved slot and
   keys 1 and 2, plus widget tests.~~ (done. The choice buttons' look moved
   into `BoardButton`, which both use. Got it / Missed it stay in view when
   the card is flipped back once answered, and are ignored while the next
   question loads, since by then moving on has already been counted.)
4. **README**, and a manual check in a browser (Playwright, as for the web UI
   and filters; remember `locale: 'en-US'`). Play a few clues and trivia
   questions, reload, see the game kept, then press New game. Also check the
   score line on a phone-sized window (360 px wide) with a four-figure
   negative score.

Commits 1–3 are the feature. Commit 2 is useful even if 3 waits.

## 7. Out of scope

- **History and all-time statistics** (per day, per category, per
  difficulty). The saved form in §3 is one game; a history would be a table
  in `user.db` next to hidden questions, with the web build needing its own
  store, as hidden questions do. That's worth its own plan once there's a
  game worth tracking.
- **Score per source.** One game covers whatever you play (§2).
- **Timers, wagers, and Daily Double or Final Jeopardy wagering.** The app
  plays clues one at a time, not as a board, so there's nothing to wager
  against.
- **Typing the response** and checking it. Matching free text against
  Jeopardy responses ("What is…", alternate spellings, partial names) is a
  project of its own, and self-report is what players use at home anyway.
- **Syncing a score between devices** through `serve_clues.py`. Hidden
  questions sync because they are facts about the questions; a score is
  about one person playing on one device.

## 8. Accessibility and layout

- The score line and Got it / Missed it have semantics labels, like the
  tick and cross on choices.
- The colours are the existing right and wrong colours, and the tick and
  cross carry the meaning for anyone who can't tell green from red.
- At 360 px the bottom row has to fit the score line and Hide Question. If
  it can't at a readable size, Hide Question moves to the score dialog's
  actions on narrow screens. Check this in commit 4 before deciding.

## 9. Risks and open questions

- **It's an honour system.** Self-report can't be checked. That's fine for
  a personal app; the score is only as honest as the player.
- **Decided:** a skip breaks the streak (§2), so skipping hard questions
  can't protect it. It still doesn't count as a miss.
- **Decided:** peeking at a multiple-choice question isn't a miss (§2);
  moving on from it is a skip.
- **Decided:** trivia questions all count the same. Difficulty could weight
  them (1, 2 or 3 points for easy, medium and hard), much as clue values
  weight Jeopardy clues, but a plain count is easier to read, and weighting
  can be added later without changing what's saved.
- **The bottom row could get crowded** on small phones (§8).
- **The saved form will grow** if history comes later (§7). The JSON has
  no version field; a history would live in its own store, so this one never
  needs migrating.
