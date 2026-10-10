# Plan: Round and air-date filters

The [web UI plan](web-ui-plan.md) is done, and it names this feature as next
(§0 and §12). `QuestionFilter` (rounds plus an air-date range) is already
handled by every source and by `serve_clues.py`, but nothing in the UI sets a
filter, so `QuizPage` always asks for `QuestionFilter.any`. This plan adds a
filter sheet and keeps the choice between launches. Because the web UI is in
place, the change reaches phones and browsers at once.

It also fixes the random pick under a date filter, which doesn't work today
(§2). That has to land first, or the new sheet would show the same clue over
and over.

## 0. What a person can do

- Choose any of **Jeopardy!**, **Double Jeopardy!** and **Final Jeopardy!**,
  so that "only Final Jeopardy" or "no Final Jeopardy" is one tap.
- Choose a **range of years**, such as "1990 to 1999" or "2015 to now".
- Keep both between launches, see in the app bar when a filter is on, and
  clear it in one tap.
- Afterwards, as a follow-up commit: choose a **difficulty**, meaning the
  clue's row on the board, from 1 (top) to 5 (bottom). See §8.

Years are as fine-grained as the picker goes. Day-level dates add a lot of UI
and little value for play. The model already takes `DateTime`s, so finer
ranges are possible later without touching the data layer.

## 1. What the code already does

| Layer | Filter support today |
|---|---|
| `QuestionFilter` (`lib/data/question_source.dart`) | `rounds`, `from`, `to`, `matches()`, value equality |
| `QuestionRepository.next` | Takes `filter` and passes it to the source |
| `LocalQuestionSource` | Turns rounds and dates into SQL |
| `HttpQuestionSource` | Clears its buffer when the filter changes. Filters on the client when the dialect can't filter on the server |
| `QuizApiDialect` | Sends `round=1,2&from=…&to=…` (`filtersOnServer`) |
| `JServiceDialect` | Nothing on the server. Its clues have no round, so a round filter matches nothing |
| `FallbackQuestionSource` | Passes the filter to both sources |
| `serve_clues.py` | Parses and applies `round`, `from` and `to` |
| `QuizPage` | **Never passes a filter** |

So the work is mostly the UI and somewhere to keep the choice, apart from
§2.

## 2. The random pick is biased under a date filter (fix first)

`LocalQuestionSource.randomQuestion` and `ClueStore.random` in
`serve_clues.py` use the same method. They pick a random clue id from 1 to
`MAX(id)` and return the first clue at or after it that matches, wrapping
around to the start. The comment in the code accepts "a little" bias. That
holds for rounds, which are spread through every game. It doesn't hold for
dates.

**Clue ids are in air-date order.** `build_clue_db.py` numbers clues in
dataset file order, and the v42 file is chronological. In a database built
from it, `air_date` never goes down as the id goes up. A date range is
therefore one block of ids. Any random start before the block lands on the
block's first clue, and so does any start after it, after the wrap.

Measured against a real `clues.db` (543,912 clues), with 200 picks per filter
using today's query:

| Filter | Matching clues | Distinct clues in 200 picks | Most common clue | Time per pick |
|---|---|---|---|---|
| none | 543,912 | 200 | 1× | 0.01 ms |
| Final Jeopardy only | 9,277 | 197 | 2× | 0.01 ms |
| Jeopardy + Double Jeopardy | 534,635 | 200 | 1× | **65 ms** |
| 2010–2014 | 67,099 | **25** | **176×** | 19 ms |
| from 2020 | 88,571 | **37** | **164×** | 27 ms |
| to 1990 | 70,664 | **24** | **177×** | 31 ms |
| Final Jeopardy in 2001 | 225 | **8** | **193×** | 4 ms |

Two problems, then:

- **Date ranges return nearly the same clue every time.** If that first clue
  is hidden, it gets worse: `QuestionRepository.next` makes 20 tries, most of
  which hit the hidden clue, and it sometimes gives up with "Every question
  tried has been hidden". On the server, `found.setdefault` dedupes, so a
  batch of 10 comes back with only a few clues. If the first clue has been
  reported, the batch can come back nearly empty.
- **Jeopardy + Double Jeopardy is slow.** SQLite answers
  `round IN (1, 2) … ORDER BY id LIMIT 1` through the `clues_round` index and
  then sorts, which takes 65 ms per pick on a laptop and longer on a phone.

**Fix (the same in Dart and Python):**

1. **Pick within the date range's ids.** For a filter with dates, find the
   lowest and highest clue id in that range, then pick the random start
   between them and wrap around to the lowest. Keep the `air_date` conditions
   in the `WHERE` as well. That way correctness never depends on the id
   order; only fairness does.
2. **Finding the range:** `games` has a unique index on `air_date`, so the
   range's first and last game ids are a cheap lookup. Clue `game_id` never
   goes down as the id goes up, so a binary search over clue ids
   (`SELECT game_id FROM clues WHERE id = ?`, about 20 primary-key lookups)
   finds the clue id bounds in under 2 ms. The simpler
   `SELECT MIN(c.id), MAX(c.id) … JOIN games … WHERE air_date BETWEEN` takes
   60–90 ms on a laptop because `clues.game_id` has no index. Adding that
   index would mean a schema bump and making everyone rebuild 87 MB, which
   isn't worth it. Cache the bounds per `(from, to)`. In the server, use a
   small dict guarded by the existing lock.
3. **Keep the planner off the round index** by writing the condition as
   `+c.round IN (…)`. The pick then walks forward by id and stops within a
   few rows: Final Jeopardy comes about once every 60 clues.
4. **Make the order a promise.** `build_clue_db.py` sorts rows by air date
   (a stable sort) before numbering them, which changes nothing for v42, and
   its tests check the order. `local_question_source_real_db_test.dart`
   checks that `game_id` never goes down as the id goes up.

With this fix, on the same database:

| Filter | Distinct clues in 200 picks | Most common clue | Time per pick |
|---|---|---|---|
| Jeopardy + Double Jeopardy | 200 | 1× | 0.01 ms |
| 2010–2014 | 199 | 2× | 0.01 ms |
| from 2020 | 199 | 2× | 0.01 ms |
| to 1990 | 200 | 1× | 0.01 ms |
| Final Jeopardy in 2001 | 129 | 4× | 0.01 ms |

Final Jeopardy in 2001 is close to a fair draw: 200 fair draws from 225
clues give about 132 distinct clues.

A range with no games (for example 1950–1960) means there are no bounds.
Throw `NoQuestionFound` without querying `clues`.

## 3. Which sources support which filters

A source should only offer filters it can apply. Add, as the
[general trivia plan](general-trivia-plan.md) §6 expects:

```dart
enum FilterKind { round, airDate }

abstract class QuestionSource {
  /// Filters this source applies reliably. The filter sheet offers only these.
  Set<FilterKind> get supportedFilters => const {};
}
```

| Source | `supportedFilters` |
|---|---|
| `LocalQuestionSource` | `{round, airDate}` |
| `HttpQuestionSource` | `dialect.supportedFilters` |
| `QuizApiDialect` | `{round, airDate}` |
| `JServiceDialect` | `{}`. Its clues have no round. Filtering by date on the client gives up after 3 batches of 10, so a narrow range fails, and jService itself is gone. |
| `FallbackQuestionSource` | Those both sources support. A filter that works on the primary and then fails on the fallback would look like a bug. |

When the set is empty, the app bar has no filter button.

`QuestionFilter` itself doesn't change. A saved filter is reduced to what the
current source supports before it's used, so a filter saved under one build
can't empty another.

## 4. Keeping the filter (`lib/data/filter_store.dart`, `QuestionRepository`)

Follow `TokenStore`:

```dart
abstract class FilterStore {
  Future<QuestionFilter> read();          // QuestionFilter.any if nothing saved or unreadable
  Future<void> write(QuestionFilter filter);
}
class InMemoryFilterStore implements FilterStore { … }      // tests
class SharedPrefsFilterStore implements FilterStore { … }   // every platform
```

- `SharedPrefsFilterStore` keeps JSON under `question_filter`:
  `{"rounds":[1,2],"from":"1990-01-01","to":"1999-12-31"}`. Missing keys
  mean "any". `shared_preferences` is already a dependency and works on
  Android, iOS and the web. Unlike hidden clues, this is a single small value,
  so it doesn't need `user.db`.
- `QuestionRepository` gains an optional `filterStore`, a
  `QuestionFilter filter` getter, and `Future<void> setFilter(QuestionFilter)`,
  which saves the filter and uses it from the next question on. `_open()`
  reads it next to the token. `next()` uses `this.filter` when no filter is
  passed in, so existing callers and tests don't change.
- `main.dart` passes `SharedPrefsFilterStore()` on every platform.
- **Normalise on save:** all three rounds is `rounds: null`, and the full year
  range is `from: null, to: null`. A filter that is "everything" then compares
  equal to `QuestionFilter.any`, so it doesn't clear `HttpQuestionSource`'s
  buffer for nothing.

## 5. UI (`lib/quiz_page.dart`, `lib/ui/filter_sheet.dart`)

**Filter button.** In the app bar, next to the info button, add a filter
button: `Icons.filter_alt_outlined` when no filter is on and
`Icons.filter_alt` when one is. Its tooltip describes the filter, for example
"Double Jeopardy!, 1990–1999", or says "Filter clues". It isn't shown when
`supportedFilters` is empty.

**Filter sheet** (`showModalBottomSheet`, at most `maxBoardWidth` wide so it
lines up with the board in a browser):

- **Rounds:** three `FilterChip`s. The last selected chip can't be turned
  off, because no rounds can't match anything.
- **Years:** a `RangeSlider` from 1984 to the current year, one division per
  year, with the two years shown as text above it. 1984 is when the
  syndicated show began, which is where the dataset starts.
- **Reset** sets everything back to "any". **Apply** saves and closes.
  Closing the sheet any other way changes nothing.
- Each section shows only if its `FilterKind` is supported.

**Applying a new filter** calls `repository.setFilter`, then loads a new
question straight away. The one on screen may not match, and a change you
can't see feels broken. If the filter didn't change, nothing reloads.

**No matching clues.** `NoQuestionFound` with a filter on currently shows
"No question matches." and a Retry button that can only fail again. While a
filter is on, show "No clues match your filters." with **Change filters**
(opens the sheet) and **Clear filters** in place of Retry. With no filter,
keep today's message and button.

**Keyboard (web and desktop):** F opens the sheet. Like the other shortcuts,
it is off while the token field is showing. It works while a question or the
no-match message is showing. Add F to the refresh button's tooltip and the
README's keyboard line. Inside the sheet, the chips and the slider already
take Tab, Space and the arrow keys, and Escape closes it.

## 6. `serve_clues.py`

- Apply §2 to `ClueStore.random`: id bounds from a binary search, cached per
  `(date_from, date_to)` under `self._lock`, and `+c.round`.
- No API change. `round`, `from` and `to` already exist.
- The README's API line already lists the parameters. Add a sentence saying
  that a filter matching nothing returns an empty `questions` list. The app
  already turns that into `NoQuestionFound`.

## 7. Tests

| File | Checks |
|---|---|
| `test/local_question_source_test.dart` | Fixture with clues across several dates: a date range returns many distinct clues (fixed `Random`), never one outside the range, and an empty range gives `NoQuestionFound`; rounds with `+c.round`; bounds are cached |
| `test/local_question_source_real_db_test.dart` (runs when `clues.db` exists) | `game_id` never goes down as the id goes up; 200 picks in 2010–2014 give at least 150 distinct clues; Jeopardy + Double Jeopardy picks take under 5 ms each on average |
| `tool/test_build_clue_db.py` | Out-of-order input rows are numbered in air-date order, and same-date rows keep their file order |
| `tool/test_serve_clues.py` | A date range returns a full batch of distinct clues; an empty range returns `[]`; rounds and dates combined |
| `test/filter_store_test.dart` (new) | Round trip; missing, corrupt and partial JSON give `any`; normalisation |
| `test/question_repository_test.dart` | `setFilter` saves and is used by the next `next()`; `open()` loads the saved filter; filters a source doesn't support are dropped |
| `test/source_config_test.dart` or a new `supported_filters_test.dart` | `supportedFilters` for each source and dialect, and the intersection for the fallback source |
| `test/widget_test.dart` | Button hidden when nothing is supported; the icon and tooltip change when a filter is on; apply reloads; Reset; the last round chip can't be turned off; the no-match state offers Change/Clear; F opens the sheet but not while the token field is showing |

`FakeQuestionSource` (`test/support/fakes.dart`) gains a `supportedFilters`
argument and records the last filter it was asked for, so widget tests can
check what reached the source.

`flutter analyze`, `flutter test`, `python3 -m unittest discover tool` and
`flutter build web` must pass at every commit.

## 8. Follow-up: difficulty by board row

This comes after the main feature (§9, commit 6). It adds a **Difficulty**
section to the sheet with five chips, row 1 (top of the board, easiest) to
row 5 (bottom, hardest).

**Why rows, not dollar amounts.** Clue values doubled on 2001-11-26 (the
last game at the old values aired 2001-11-23), and Double Jeopardy doubles
them again. So the same amount sits on different rows:

| Value | Jeopardy, before 2001 | Double Jeopardy, before 2001 | Jeopardy, 2001 on | Double Jeopardy, 2001 on |
|---|---|---|---|---|
| $400 | row 4 | row 2 | row 2 | row 1 |
| $1,000 | — | row 5 | row 5 | — |

A dollar range would mean "hard" in one era and "middle of the board" in
another. A row means the same thing everywhere.

**The data supports it.** A clue's row is its value divided by the round's
base: $100 for Jeopardy before 2001-11-26, $200 for Double Jeopardy before
then and for Jeopardy since, and $400 for Double Jeopardy since. Measured on
the real `clues.db`, every Jeopardy and Double Jeopardy clue works out to a
row from 1 to 5, with none left over. Each row holds 104,640–108,672 clues.
Row 5 has the fewest, probably because the bottom row most often runs out of
time before every clue is revealed. Daily Doubles keep their board value, so
they have a row too (mostly rows 3–5) and play as regular clues in it (§10). No new column, index or schema bump is
needed.

**Final Jeopardy has no row.** Its value is stored as 0. The row filter only
narrows Jeopardy and Double Jeopardy clues; Final Jeopardy clues pass it
whenever their round is selected. "Rows 4–5 plus Final Jeopardy" then means
what it says. When Final Jeopardy is the only round selected, the Difficulty
section is greyed out with "Final Jeopardy has no board row".

**Model and filter.**

- `JeopardyQuestion.boardRow` (`int?`): computed from `value`, `round` and
  `airDate`. It is null for Final Jeopardy, when any of the three is missing,
  or when the value doesn't divide into a row from 1 to 5. The era boundary
  is one constant, `valuesDoubledOn = DateTime(2001, 11, 26)`, next to the
  model.
- `QuestionFilter.boardRows` (`Set<int>?`). `matches()` lets Final Jeopardy
  through and otherwise requires `boardRows.contains(q.boardRow)`. It joins
  `==`, `hashCode`, the §4 normalisation (all five rows is `null`) and the
  `FilterStore` JSON (`"rows":[4,5]`). A saved filter without `rows` reads as
  any row.
- `FilterKind.boardRow`. `LocalQuestionSource` and `QuizApiDialect` add it;
  jService doesn't (its clues have no round, so no row).

**SQL (`LocalQuestionSource` and `serve_clues.py`).** One shared expression:

```sql
-- base: 100, 200 or 400 depending on round and era
CASE c.round WHEN 1 THEN 100 ELSE 200 END
  * CASE WHEN g.air_date >= '2001-11-26' THEN 2 ELSE 1 END
-- condition:
(c.round = 3 OR (c.value % base = 0 AND c.value / base IN (?, …)))
```

Rows are spread evenly through every game, so the pick from §2 stays fast
and fair. With this condition, picks for row 5 alone and for rows 1–2 took
about 0.01 ms each and returned 300 different clues in 300 picks.

**API (`quizapp` v1, additive).** `GET /v1/random` takes `row=1,2,…`.
`serve_clues.py` rejects anything outside 1–5 with 400, like `round`.
`QuizApiDialect` sends the rows sorted. An older server ignores the
unknown parameter (`parse_random_query` ignores unknown parameters), but
`HttpQuestionSource` still checks `filter.matches()` on each question it
buffers, so the filter holds. Requests just take more batches, because
dropped questions have to be replaced. Update the API line in
`serve_clues.py`'s docstring and the README.

**Sheet.** In the Difficulty section, chips 1–5 with "1 = top row, 5 =
bottom row" under them. As with rounds, the last selected chip can't be
turned off. The app bar tooltip adds "rows 4–5".

**General trivia.** OpenTDB's easy/medium/hard (general trivia plan §6)
becomes its own `FilterKind.difficulty`, not a mapping onto rows. The sheet
has one "Difficulty" section and shows whichever kind the source supports.

**Tests.**

| File | Checks |
|---|---|
| `test/question_test.dart` | `boardRow` for each round on both sides of 2001-11-26; null for Final Jeopardy, a missing value or date, and odd values |
| `test/local_question_source_test.dart` | Fixture with clues on both sides of the boundary: only the chosen rows come back; Final Jeopardy passes when its round is on; rows combined with a date range |
| `test/local_question_source_real_db_test.dart` | Every non-Final clue has a row from 1 to 5; 200 picks for row 5 give at least 150 distinct clues |
| `tool/test_serve_clues.py` | `row=` parsing and the 400; the same row results as the Dart version for shared test clues |
| `test/http_question_source_test.dart` | `row` in the `quizapp` URL; client-side row filtering when an old server ignores it |
| `test/filter_store_test.dart`, `test/widget_test.dart` | `rows` round trip and normalisation; the section, the last-chip rule, greyed out for Final Jeopardy only, tooltip text |

## 9. Suggested commit order

1. **Fair random picks under filters.** §2 in `LocalQuestionSource`,
   `serve_clues.py` and `build_clue_db.py`, plus their tests. This needs no
   UI and fixes a real bug for anyone already sending `from`/`to` to the
   server.
2. **`supportedFilters`**, on the sources and dialects, plus tests.
3. **`FilterStore` and `QuestionRepository.setFilter`**, plus tests.
4. **Filter sheet, app bar button and no-match state**, plus widget tests.
5. **Keyboard shortcut, README**, and a manual check in a browser (Playwright,
   as for the web UI). Set a filter, reload, see it kept, and get a clue from
   the range. Then pick an empty range and use Clear filters.

6. **Difficulty by board row** (§8): `boardRow`, `QuestionFilter.boardRows`,
   the SQL in both places, the `row` API parameter, the sheet section and
   tests. This is a separate commit after the main feature has landed, so
   it can be reviewed and tried on its own.

Commits 1–4 are the feature. Commit 1 is worth landing even if the rest
slips. Commit 6 is the planned follow-up.

## 10. Risks and open questions

- **The id order is an assumption about the data.** §2 makes the builder
  guarantee it and a test check it. If it ever breaks, picks stay correct,
  because the `WHERE` still filters by date. Only fairness suffers.
- **The year bounds are Jeopardy-specific.** 1984 is hard-coded because the
  `quizapp` API has no way to report its date range. A later `/v1/info`
  could, and so could a `QuestionSource` getter for the local database
  (`MIN(air_date)` on `games` is cheap). General trivia has no air dates, so
  §3's `supportedFilters` hides the section for it.
- **A filter can be saved that a later build can't apply** (for example,
  after switching to jService). §3 drops the unsupported parts instead of
  failing. The sheet then shows what's actually in use.
- **Hidden clues under a narrow filter.** With fair picks, the repository's
  20 tries only run out when nearly every matching clue is hidden. That's the
  right time to say so. The no-match state then offers to change the filter.
- **The 2001 value change is hard-coded** for board rows (§8), in Dart and
  in Python. Values haven't changed since, and a shared test vector keeps
  the two copies in step. If they ever change again, it becomes a list of
  dates, which only touches the base calculation.
- **Decided:** no dollar-value filter. Board rows (§8) cover it in a way that
  means the same thing in every era.
- **Decided:** Daily Doubles play as regular clues and get no filter of
  their own. Their stored value is their board slot, not the wager: in all
  26,310 category columns with a Daily Double, no Daily Double shares a
  value with another clue in its column. So the row filter (§8) treats them
  like any clue in their row, and the card shows their board value instead
  of "DAILY DOUBLE" (already done, separately from this plan). The wager
  stays in `dailyDoubleWager` and the raw data.
- **Next after this:** general trivia and multiple choice
  ([general-trivia-plan.md](general-trivia-plan.md)). Its §6 filter fields
  (category, difficulty) slot into `FilterKind` and the sheet this plan adds.
