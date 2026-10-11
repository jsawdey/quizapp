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
- **Skipping is free.** Loading the next question without answering doesn't
  count either way, so the app still works as a flash card for anyone who
  doesn't want a score.
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

**Streak.** Right answers in a row. A miss sets it to 0; `best` keeps the
highest it has reached. Skipped questions don't touch it (see §9).

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
answered it. Hiding one you haven't scored counts nothing, as with a skip.

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

  static const empty = Score(...);
  Score record(Question question, {required bool right, DateTime? now});
}
```

`record` returns the new score, with the rules from §2 in one place. It is
plain Dart, so the arithmetic is unit tested without widgets.

**`lib/data/score_store.dart`**: `ScoreStore` with `read()` and
`write(Score)`, plus `InMemoryScoreStore` and `SharedPrefsScoreStore`.
These mirror `FilterStore`. The saved form is one JSON value under the key
`score`:

```json
{"answered":10,"right":7,"streak":3,"best":5,"dollars":4200,"valued":8,"started":"2026-10-11"}
```

A missing or unreadable value, or one with a negative count, is read as
`Score.empty`. Writing `Score.empty` removes the key.

**`lib/controller/score_keeper.dart`**: a `ChangeNotifier` that the page
listens to.

```dart
class ScoreKeeper extends ChangeNotifier {
  ScoreKeeper({required ScoreStore store});
  Score get score;
  Future<void> open();            // reads the saved game; safe to call twice
  void record(Question question, {required bool right});
  void newGame();
}
```

- **Changing your mind** about Got it or Missed it works by keeping the
  score from before the first result for the current question. A second
  `record` for the *same* question (`identical`, not just the same key)
  recomputes from that snapshot instead of adding again. Streak and best
  can't be undone by subtracting, so recomputing is the only correct way.
  The snapshot is dropped when a different question is recorded, and is
  never saved: after a relaunch the old question is gone anyway.
- **Saving** happens after every change, without waiting for it. A failed
  save is only logged (as with the filter): the score still counts until
  the app closes.
- **Opening:** `main.dart` creates the keeper and calls `open()` alongside
  the repository. If a result is recorded before the saved game has been
  read, the saved game wins and the new result is applied on top of it, the
  same rule as "a filter chosen while opening wins over the saved one",
  turned around because results add up instead of replacing.

## 4. UI (`lib/quiz_page.dart`, `lib/ui/`)

`QuizPage` and `QuizApp` take an optional `ScoreKeeper? scoreKeeper`, as
they take `sources`. With none, the page looks and behaves exactly as now:
no score line and no Got it / Missed it. That keeps the existing widget tests
as they are, and `main.dart` always passes one.

**Page state.** `_QuizPageState` gains `bool? _gotIt` (the self-report for
the current open question) and `bool _peeked` (the response was shown before
a choice was picked). Both reset in `_loadQuestion`, next to `_picked`.

- `_toggleAnswer` sets `_peeked` if there are choices and `_picked` is null.
- `_pick` calls `scoreKeeper.record(current, right: choice == current.answer)`
  unless `_peeked`.
- `_report(bool gotIt)` sets `_gotIt` and calls `record`. Calling it again
  with the other value is the change of mind from §3.

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

**Score dialog:** an `AlertDialog` titled "Score", with one line per figure
from §0, "Started Oct 11" from `started`, and the actions **New game** and
**Close**. New game asks nothing further: opening the dialog and pressing
the button is already two deliberate steps, and the button only clears the
score, never hidden questions or the filter.

## 5. Tests

| File | Checks |
|---|---|
| `test/score_test.dart` | Right and wrong; streak and best; Coryat adds and subtracts the value; Final Jeopardy and trivia questions count without dollars; a Daily Double adds its board value when right and subtracts nothing when wrong; `started` set by the first result only |
| `test/score_store_test.dart` | JSON round trip; missing, malformed and negative values read as `Score.empty`; writing empty removes the key |
| `test/score_keeper_test.dart` | Records and saves; changing your mind from right to wrong and back gives the same score as recording once, streak and best included; a different question drops the snapshot; `newGame`; a save that fails still counts; a result recorded while opening lands on top of the saved game |
| `test/widget_test.dart` | A pick updates the score line; peeking then picking leaves it unchanged; Got it / Missed it only after the response shows, and switching between them; keys 1 and 2; no score UI without a keeper; dialog figures and New game; the score line survives a source switch, a filter change and a hide; a game saved by one keeper is shown by a new one with the same store |

`test/support/fakes.dart` already makes questions with and without values,
rounds and choices, which covers every case in §2.

## 6. Suggested commit order

1. **`Score`, `ScoreStore` and `ScoreKeeper`**, plus their tests. No UI;
   nothing calls them yet.
2. **Multiple-choice scoring**: the score line, the dialog with New game,
   peeking, and `main.dart` creating the keeper, plus widget tests. This is
   the smallest change that turns trivia into a game, and it can be tried
   against OpenTDB on its own.
3. **Got it / Missed it** for open questions, with the reserved slot and
   keys 1 and 2, plus widget tests.
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

- **It's an honour system.** Self-report can't be checked, and skipping
  hard questions protects a streak. That's fine for a personal app; the
  percentage and the dollar score are only as honest as the player.
- **Open: should skipping break the streak?** This plan says no, so the app
  stays a flash card for anyone who ignores the score. The other choice is
  that a question you *revealed* but didn't score breaks it. It's a
  one-line change in `ScoreKeeper` if you prefer that.
- **Open: should peeking count as a miss?** This plan says no (§2). If it
  ever should, it's the same one place.
- **Open: is a percentage enough for trivia?** Difficulty could weight
  trivia questions (1, 2 or 3 points for easy, medium and hard), much as
  clue values weight Jeopardy clues. Left out for now: a plain count is
  easier to read, and weighting can be added later without changing what's
  saved.
- **The bottom row could get crowded** on small phones (§8).
- **The saved form will grow** if history comes later (§7). The JSON has
  no version field; a history would live in its own store, so this one never
  needs migrating.
