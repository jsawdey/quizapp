# Plan: Trivia from sources other than Jeopardy!

The app reads Jeopardy! clues from a local database built from the jwolle1
dataset, from `serve_clues.py`, or from a jService-style API (see the
[question backend plan](question-backend-plan.md)). This plan lets it also
serve **general trivia**, including **multiple-choice** and **true/false**
questions, starting with the [Open Trivia Database](https://opentdb.com)
(OpenTDB).

It builds on the [web UI plan](web-ui-plan.md) and should come after it, so
the new card mode is written once for phones and browsers.

**Status:** commits 1–5 of §9 are done; only The Trivia API dialect
(commit 6, optional) is left. In order: the rename; the model and UI for
choices, difficulty and attribution; real OpenTDB responses in
`test/support/opentdb/`, which corrected §1, §4 and §10 (see "Checked
against the live API" in §4); `OpenTdbDialect`; and the offline copy with
category and difficulty filters.

Where the code differs from this plan:

- Commits 1–2 (§2–§3): the seeded shuffle waited for the OpenTDB dialect
  (commit 4), the first source that needs it, because the `quizapp` API
  sends choices in display order; and "About questions" is a copyright
  button in the app bar, shown only when the source needs credit, since the
  app bar has no menu.
- Commit 4: codes 3 and 4 both get a new token (a new token has seen
  nothing, so `api_token.php?command=reset` is never needed), and only
  batch requests are paced, so the token request at startup doesn't hold up
  the first question.
- Commit 5, filters (§6): the filter sheet gained Categories and Difficulty
  sections. Choosing no category means every category. `OpenTdbDialect`
  fetches category ids when the sheet first asks, not in `open()`, and a new
  `ApiDialect.prepare` hook counts each chosen category's questions
  (`api_count.php`) before the first batch for a filter, so a batch asks for
  no more than its category holds (the code 1 cap from §4). Each batch draws
  from one category and difficulty, in proportion to their size.
- Commit 5, offline (§7): the local trivia source picks with a random
  `OFFSET` among the matches, counted once per filter, which is exactly fair
  at a few thousand rows; the ids don't need any order. `serve_clues.py`
  answers a new `GET /v1/info` (question backend plan §7), which tells the
  app whether it holds clues or trivia, its filters, categories and credit.
  `trivia.db` stays out of web builds: the web build can't open SQLite, so
  the browser plays it through `serve_clues.py`.

## 0. Why, and what's in the way

**Why bother:**

- **Variety.** Jeopardy clues are one style: a statement answered with "What
  is…". General trivia adds easier questions, difficulty levels and choices,
  which suit casual play and play with other people.
- **Licensing.** The jwolle1 dataset forbids public-facing use, which is why
  the app and `serve_clues.py` stay personal and LAN-only. OpenTDB is
  licensed CC BY-SA 4.0, so with attribution its questions can be copied,
  served and shown publicly.
- **Resilience.** Because of that license, OpenTDB questions can be copied
  into a local database (§7), just like the Jeopardy clues. The app then
  doesn't depend on a hosted service staying up, which is how jService broke
  it.

**What's in the way** (from reading the code):

| Coupling | Where | Severity |
|---|---|---|
| Questions can only be flip cards: no answer choices in the model, and the only interaction is reveal | `JeopardyQuestion`, `QuizPage` | **Blocking** for multiple choice |
| Filters are Jeopardy concepts (round, air date) | `QuestionFilter` | Low: no UI uses filters yet |
| A dialect is stateless and has one request shape: no session tokens, no minimum gap between requests, fixed batch size | `ApiDialect`, `HttpQuestionSource` | Medium for OpenTDB (§4) |
| Hiding needs a stable key, and OpenTDB questions have no id | `HiddenQuestionStore` | Low: derive one (§4) |
| `sanitize` only strips `<i>` | `JeopardyQuestion.sanitize` | Low: OpenTDB can URL-encode its text (§4) |
| The local database and `serve_clues.py` only know the clues schema | `LocalQuestionSource`, `serve_clues.py` | Medium; only for offline use (§7) |
| Names and look: `JeopardyQuestion`, Korinna capitals, gold dollar line | model, theme | Cosmetic |

What already generalizes: the `QuestionSource`/`ApiDialect` seam, optional
Jeopardy fields (value, round, wager and air date all degrade to "not
shown"), per-source hidden ids, prefetching, the fallback source, and
build-time config.

## 1. Sources considered

The OpenTDB details were checked against the live API on 2026-10-10 (§9,
commit 3; the corrections are in §4). The Trivia API's still come from search
summaries; check them the same way before writing its dialect.

| Source | Shape | License | Ids | Notes |
|---|---|---|---|---|
| **Open Trivia DB** | `GET /api.php?amount=N&category=&difficulty=&type=&encode=&token=` → `{response_code, results: [{type, difficulty, category, question, correct_answer, incorrect_answers}]}` | CC BY-SA 4.0 | none | Asks for one request per IP every 5 s; bursts get `response_code` 5 with HTTP 429. Session tokens stop repeats. About 5,300 verified questions (`api_count_global.php`); community dumps exist. |
| The Trivia API | `GET /v2/questions?limit=&categories=&difficulties=` → `[{id, category, question: {text}, correctAnswer, incorrectAnswers, difficulty, tags, type}]` | CC BY-NC 4.0 | yes | Free for non-commercial use (this app is personal). Commercial use and advanced features are paid. |

**Recommendation: OpenTDB first.** Its license allows a local copy (§7),
which fits this app's local-first design. Its API is also the harder of the
two (tokens, rate limit, no ids), so building it first proves out the
`ApiDialect` changes. The Trivia API can follow as a ~100-line dialect (§9,
commit 6).

## 2. Model (`lib/model/question.dart`)

Rename `JeopardyQuestion` → `Question` in a separate, purely mechanical
commit. It touches most files and tests, so keeping it apart keeps the
behavioural diffs readable. Then add:

```dart
enum QuestionFormat { open, multipleChoice, trueFalse }

class Question {
  ...existing fields...
  /// Every option in display order, including [answer]. Null for open questions.
  final List<String>? choices;
  /// 'easy' | 'medium' | 'hard'; null when the source doesn't say.
  final String? difficulty;

  QuestionFormat get format => choices == null ? QuestionFormat.open
      : choices!.length == 2 && choices!.toSet().containsAll(['True', 'False'])
          ? QuestionFormat.trueFalse : QuestionFormat.multipleChoice;
}
```

- **The parser shuffles the choices**, seeded by the question key so the
  order is stable across rebuilds and devices. True/false stays
  `['True', 'False']`. The UI never shuffles.
- Constructor check: when `choices` is set, it must contain `answer`. A
  source that breaks this drops the item, the same way items that fail to
  parse are dropped today.
- `isFinalJeopardy`, `round`, `value` and `dailyDoubleWager` stay. They're
  null for general trivia, and the UI already handles that.

## 3. UI (`lib/quiz_page.dart`, `lib/ui/quiz_question/`)

- **Open questions** don't change: tap to flip.
- **Multiple choice / true-false:** the clue panel shows the question, with a
  new `ChoiceListWidget` underneath that has one button per choice (in two
  columns on wide screens). Tapping a choice:
  - marks the right choice green and, if you picked another one, yours red;
  - turns off the choice buttons;
  - leaves the card unflipped.

  Tapping the clue panel before choosing just reveals the answer, as today,
  for people who want to play it as a flash card.
- **Keyboard (web):** keys 1–4 pick a choice, on top of the web plan's
  Space, N and H.
- **The detail line** under the category shows `difficulty` in capitals
  ("MEDIUM") when there is no Jeopardy value or round. The colour stays gold.
- **Attribution:** `QuestionSource` gains `String? get attribution`. The info
  overlay shows it as a footer, and so does a new "About questions" entry in
  the app bar menu. CC BY-SA and CC BY-NC both require attribution, so this
  is a requirement, not polish.
- **Layout:** the clue panel shrinks when choices are shown. Give it
  `flex: 3` and the choices `flex: 2` in that case; the existing text
  scaling handles long questions.

## 4. `OpenTdbDialect` (`lib/data/api_dialect.dart`) and `HttpQuestionSource` changes

**Dialect hooks** (all have defaults, so `quizapp` and `jservice` don't
change):

```dart
abstract class ApiDialect {
  int get batchSize => 10;                    // OpenTDB: 50 (its max)
  Duration get minRequestInterval => Duration.zero;  // OpenTDB: 5 s, plus margin
  /// Called once by HttpQuestionSource.open(); may make requests (session token).
  Future<void> open(ApiRequester http, Uri base) async {}
  /// Thrown by parseRandom to ask for open() again and one retry.
  // class SessionExpired implements Exception
}
```

`ApiRequester` is a narrow wrapper over `HttpQuestionSource._send` (GET
returning decoded JSON), so dialects get the same timeout and error mapping.
`HttpQuestionSource`:

- takes `batchSize` and `refillAt` from the dialect;
- waits out `minRequestInterval` since the last request before sending. With
  batches of 50, a person never waits on this in practice;
- on `SessionExpired`, calls `dialect.open` again and retries the batch once,
  then gives up with `SourceUnavailable`.

**OpenTDB specifics:**

- **Request:** `api.php?amount=50&encode=url3986&token=…`. URL encoding
  avoids parsing HTML entities: `question`, `correct_answer`, each of
  `incorrect_answers` and `category` go through `Uri.decodeComponent`, then
  `trim()` (some answers have a stray leading or trailing space). `type` and
  `difficulty` aren't encoded. Optional filters (§6) add `category`,
  `difficulty` and `type`.
- **Session:** `open()` requests a token from
  `api_token.php?command=request`. Response code 3 (token not found or
  expired) raises `SessionExpired`, which gets a new token. Code 4 (every
  question already served) resets the token
  (`api_token.php?command=reset&token=…`) and retries. Code 5 (rate limit)
  becomes `SourceUnavailable('Open Trivia DB is rate limiting; try again in a
  few seconds')`. Code 1 (no results) becomes `NoQuestionFound`, and code 2
  (invalid parameter) becomes `SourceUnavailable`.
- **Keys:** `sha256(category \0 question \0 correct_answer)`, on the decoded,
  trimmed text, the first 16 hex
  characters, with source id `opentdb`. This needs `package:crypto`, which
  works on every platform including the web. If OpenTDB edits a question's
  text, a hidden question comes back. That's acceptable.
- **Mapping:**
  - `type: multiple` → 4 choices;
  - `type: boolean` → `['True', 'False']`;
  - `category` keeps its prefix as sent (`Entertainment: Film`). The
    category widget already scales long text;
  - `difficulty` maps directly;
  - the whole item goes into `raw`.
- **Reporting:** OpenTDB has no report API, so `supportsReport` is false and
  hiding stays local.
- **`attribution`:** "Questions from Open Trivia Database (opentdb.com),
  CC BY-SA 4.0".

**Config:** `QUESTION_API_DIALECT=opentdb` and
`QUESTION_API_URL=https://opentdb.com`. There's no default URL: as in the
backend plan (§6), no hosted service is a default. With
`api_with_local_fallback`, a downed OpenTDB falls back to the local database
(Jeopardy clues, or OpenTDB's own copy after §7).

**Web:** this is the first source that's on a different origin from the
page. OpenTDB sends `access-control-allow-origin: *` on `api.php`,
`api_token.php` and `api_category.php`, so the web build can call it
directly. Web config only defaults to the page's own server and `quizapp`, so
`QUESTION_API_URL=https://opentdb.com` and `QUESTION_API_DIALECT=opentdb`
work there once the dialect exists.

**Checked against the live API** (2026-10-10, `tool/capture_opentdb.py`,
saved in `test/support/opentdb/` with each request's URL and HTTP status).
What differs from the above, and what the dialect must do about it:

- **Code 5 comes with HTTP 429**, and its body says `result`, not `results`.
  `HttpQuestionSource._send` turns any non-2xx into `SourceUnavailable`
  before a dialect sees the body, so the friendly message belongs there: map
  429 to "<source> is busy; try again in a few seconds" for every dialect.
  The limit is looser than documented: requests a second apart were never
  refused, but parallel bursts of 8 lost 2–3. The 5 s pacing stays, as the
  documented rule.
- **Code 1 is all or nothing.** Asking for more questions than a filter
  matches returns code 1 and no questions, with or without a token, instead
  of a short page. Unfiltered (5,000+ questions) that never happens, but
  with a category and difficulty (Musicals & Theatres, hard: 11 questions) a
  batch of 50 always fails. When a category is set, cap `amount` at the
  count from `api_count.php?category=N` for the chosen difficulty, fetched
  once per filter. `api_count.php` doesn't count by type, so a `type` filter
  also needs a retry with half the amount on code 1, down to 1, before
  `NoQuestionFound`.
- **An unknown category is code 1, not 2.** Code 2 is only for malformed
  parameters (`amount=0`). So a wrong category id looks like "no questions";
  map names to ids only from `api_category.php`.
- **Code 4 is also all or nothing.** With 2 unseen questions left on a
  token, a request for 5 gets code 4, while a request for 2 gets both. Reset
  and retry as above: that drops at most a batch of unseen questions, which
  is fine.
- **`amount` over 50 is capped silently** (code 0, 50 questions), so 50 is
  the batch size to use.
- **Token responses:** `request` returns `{response_code, response_message,
  token}`; `reset` returns `{response_code: 0, token}` with the same token.
  Tokens are 64 hex characters.


## 5. The `quizapp` API (v1, additive)

Add two optional fields to each question in `/v1/random`:

```json
{ "key": "...", "category": "...", "clue": "...", "response": "...",
  "choices": ["...", "...", "...", "..."], "difficulty": "medium", ... }
```

They are optional, so existing servers and clients are unaffected and the
path stays `/v1` (§7 of the backend plan allows additive changes).
`QuizApiDialect` reads them, and the Jeopardy fields stay optional as they
already are. Any server speaking the contract can then serve multiple choice,
including `serve_clues.py` after §7.

## 6. Filters (coordinate with the filter-UI feature)

`QuestionFilter` gains `Set<String>? categories` and
`Set<String>? difficulties`, and `QuestionSource` gains
`Set<FilterKind> get supportedFilters`. The filter screen, which is planned
separately, then shows only the filters the current source supports:
round and air date for Jeopardy, category and difficulty for OpenTDB.

This plan adds the fields, `matches()` support and OpenTDB's server-side
mapping. OpenTDB categories are numeric ids from `api_category.php`;
`OpenTdbDialect` fetches that list in `open()` and maps names to ids. The UI
is left to the filter feature.

## 7. Offline OpenTDB (optional)

- **`tool/build_trivia_db.py`** (standard library only) pages through
  OpenTDB with a session token at one request every 5 s. That's about 2
  minutes per 1,000 questions. It writes `assets/db/trivia.db`:

  ```sql
  CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);  -- schema_version, dataset_namespace='opentdb',
                                                          -- dataset_kind='trivia', license, attribution, fetched_at
  CREATE TABLE questions (id INTEGER PRIMARY KEY,      -- 1..N, no gaps (random pick, as clues.db)
                          key TEXT UNIQUE NOT NULL,     -- same sha256 key as the dialect
                          category TEXT NOT NULL, difficulty TEXT, question TEXT NOT NULL,
                          answer TEXT NOT NULL, choices TEXT);  -- JSON array, display order
  ```

  The keys match the live dialect, so hides carry across the API and the
  local copy, as they do for `jwolle1` today.
- **`LocalQuestionSource`** reads `meta.dataset_kind`. For `trivia`, it
  queries `questions` instead of the clue joins. The pick-a-random-id logic
  is the same, so this is a second `_select`/`_fromRow` pair, not a new
  source.
- **`ClueDatabase`** generalizes to an asset name: `clues.db` or `trivia.db`,
  chosen by a new `LOCAL_DATASET` define (default `clues`).
- **`serve_clues.py`** serves either database (`--db assets/db/trivia.db`),
  emitting `choices` and `difficulty` per §5. It prints the
  personal-use warning only for datasets without an open license
  (`meta.license`), which relaxes the web plan's LAN-only rule for OpenTDB.
- **Bundling:** `trivia.db` is small (a few MB). It is git-ignored like
  `clues.db` but, unlike `clues.db`, *may* be included in web builds. The
  web plan's `platforms:` asset filter becomes two entries.

## 8. Tests

| File | Checks |
|---|---|
| `test/question_test.dart` | `format` for each shape; `choices` must contain `answer`; seeded shuffle is stable |
| `test/http_question_source_test.dart` | dialect `batchSize`/`refillAt`; `minRequestInterval` with a fake clock; `SessionExpired` → reopen and retry once, then `SourceUnavailable` |
| `test/opentdb_dialect_test.dart` | saved real responses (multiple, boolean, each `response_code`); URL decoding; key derivation and stability; token request, reset and expiry; category id mapping |
| `test/api_dialect_test.dart` (quizapp) | `choices`/`difficulty` read when present, ignored when absent |
| `test/widget_test.dart` | choice buttons render; right/wrong colouring; disabled after choosing; tap-to-reveal still works; keys 1–4; difficulty in the detail line; attribution in the overlay |
| `tool/test_build_trivia_db.py` | from saved pages: schema, gap-free ids, keys match the Dart derivation (shared test vectors), rate-limit pacing with a fake sleep |
| `tool/test_serve_clues.py` | serves `trivia.db` with `choices`; warning suppressed for open-licence datasets |
| `test/local_question_source_test.dart` | `dataset_kind=trivia` rows → `Question` with choices |

`flutter analyze`, `flutter test`, `python3 -m unittest discover tool` and
`flutter build web` must pass at every commit.

## 9. Suggested commit order

1. **Rename** `JeopardyQuestion` → `Question` (mechanical, no behaviour
   change).
2. **Model and UI:** `choices`, `difficulty`, `format`, `ChoiceListWidget`,
   the difficulty line, `attribution`, and `quizapp` API reading of the §5
   fields. Testable with a fake source and no new backend.
3. **Capture samples:** from a machine with internet access, save real
   OpenTDB responses (one per `response_code`, plus token and category
   endpoints) under `test/support/opentdb/`. Fix anything in §1/§4 that turns
   out wrong.
4. **`OpenTdbDialect`** and the `ApiDialect`/`HttpQuestionSource` hooks
   (batch size, pacing, session), plus config, README and tests.
5. **Offline copy (optional):** `build_trivia_db.py`,
   `LocalQuestionSource`/`ClueDatabase` support, `serve_clues.py` support and
   the §6 filter fields.
6. **The Trivia API dialect (optional):** ids and server-side filters, no
   session. Small once commit 4's hooks exist.

Commits 1–4 are the feature. Commits 5 and 6 can wait or be dropped.

## 10. Risks and open questions

- **API details can drift.** OpenTDB was checked on 2026-10-10 (§4); rerun
  `tool/capture_opentdb.py` and the dialect tests if it starts misbehaving.
  The Trivia API is still unchecked.
- **Rate limit.** One request every 5 seconds per IP is shared by every
  device behind your router. Batches of 50 and the pacing in §4 keep normal
  play well under it, but several devices starting at once can get code 5
  (HTTP 429). In practice OpenTDB tolerates more than its documented rate.
  The offline copy (§7) removes the problem.
- **One category and difficulty per request.** §6 plans sets of categories
  and difficulties, but `api.php` takes one of each. A filter with several
  needs a batch per value (picking one at random per batch keeps it fair
  enough), each subject to the code 1 cap in §4.
- **Licence obligations.** CC BY-SA requires attribution (§3) and that
  redistributed copies of the questions stay under CC BY-SA. That covers
  `trivia.db` if you ever share it, not the app's code. CC BY-NC (The Trivia
  API) rules out commercial use.
- **Hidden keys come from the text.** If OpenTDB edits a question, it gets a
  new key and a hidden question can come back. That's rare and harmless.
- **Look and feel.** Jeopardy styling (Korinna capitals, blue panels) on
  general trivia is a matter of taste. Theming is out of scope; the app keeps
  one look.
- **Open:** whether a build should mix sources (Jeopardy and OpenTDB in one
  session). This plan keeps one source per build, as now. Mixing would be a
  `MixedQuestionSource` that picks between several sources by weight. It's
  easy to add later because hidden ids are already per source.
