# Plan: Replace jService with cluebase

jservice.io has been shut down, so the app can no longer load questions. This
plan moves the app to [cluebase](https://cluebase.readthedocs.io/en/latest/#endpoints).

## 1. Where the app uses jService today

| File | What it does |
| --- | --- |
| `lib/model/jservice_api.dart` | `JServiceAPI`: `GET http://jservice.io/api/random?count=N` and `POST /api/invalid?id=N` using `dart:io` `HttpClient` |
| `lib/controller/question_repository.dart` | `JServiceQuestionRepository`: fetches one random clue, loops while `invalid_count != 0`, and forwards "report question" to `/api/invalid` |
| `lib/model/question.dart` | `JeopardyQuestion.fromJson`: reads `id`, `question`, `answer`, `value`, `category.title`, `airdate` |
| `lib/quiz_page.dart` | Uses the repository; the "Report Question" button calls `markQuestionInvalid` |
| `README.md`, `pubspec.yaml` | Mention jService in their descriptions |

## 2. The cluebase API (check these against the docs)

The docs site was blocked from the environment where this plan was written.
The details below come from what we already know about cluebase. **Check each
item marked ⚠️ before writing code.**

- Base URL: `https://cluebase.lukelav.in` (HTTPS) ⚠️
- Every response is wrapped in an envelope: `{"status": "success", "data": [...]}` ⚠️
- Endpoints the app needs:
  - `GET /clues/random?limit=N`: random clues ⚠️ (find the maximum `limit`)
  - `GET /games/{id}`: game details, including `air_date` ⚠️
- Other endpoints that could be useful later: `/clues`, `/clues/{id}`,
  `/categories`, `/games`, `/games/random`, `/contestants`,
  `/contestants/{id}`, plus `limit`/`offset`/`order_by`/`sort` paging options ⚠️
- Fields on a clue: `id`, `game_id`, `value`, `daily_double`, `round`,
  `category` (plain string), `clue`, `response` ⚠️ (check whether `value` is an
  int, a string, or null for Final Jeopardy)
- Fields on a game: `id`, `episode_num`, `season_id`, `air_date`, `notes`,
  contestants, and scores ⚠️ (check the `air_date` format)
- **cluebase has no "invalid" or report endpoint**, and clues carry no `invalid_count`.

## 3. Field mapping

| `JeopardyQuestion` | jService | cluebase |
| --- | --- | --- |
| `id` | `id` | `id` |
| `question` | `question` | `clue` |
| `answer` | `answer` | `response` |
| `value` | `value` | `value` (convert if it's a string, allow null) |
| `category` | `category.title` | `category` |
| `airDate` | `airdate` | **not on the clue**: needs `/games/{game_id}` → `air_date` |
| `rawJson` | whole clue | clue JSON plus a nested `game` object (for the info overlay) |

## 4. Implementation steps

### Step 1: API client
- Add `lib/model/cluebase_api.dart` with a `ClueBaseAPI` class:
  - `Future<List<dynamic>> getRandomClues(int limit)` calls `Uri.https(host, '/clues/random', {'limit': ...})`,
    checks the status code, decodes the JSON, checks `status == 'success'`, and returns `data`.
  - `Future<Map<String, dynamic>> getGame(int id)` calls `/games/{id}` and returns `data[0]`.
  - Let callers pass in the `HttpClient` (default is a shared one) so tests can mock it.
- Delete `lib/model/jservice_api.dart`.
- Use **HTTPS**. jService used `Uri.http`, which Android 9+ blocks by default for cleartext traffic anyway.

### Step 2: Model (`lib/model/question.dart`)
- Replace `fromJson` with a cluebase version, `fromClueBaseJson(clue, {game})`, that uses the mapping above.
- Make `airDate` nullable. `formattedDateTime()` returns `''` when it's missing,
  so the app still shows a question if the game lookup fails.
- Keep `_sanitizeString` (it removes `<i>` tags and backslashes), and check
  whether cluebase text also needs HTML entities (like `&amp;`) decoded.
- Handle a null or string `value` safely.

### Step 3: Repository (`lib/controller/question_repository.dart`)
- Rename `JServiceQuestionRepository` to `QuestionRepository`.
- `getRandomQuestion()`:
  1. Fetch a small batch (for example `limit=10`) and keep the first clue that passes the checks below.
     This replaces the `invalid_count` loop and fixes its bug: the loop called
     `int.parse` on a value that was already an int.
  2. Then fetch `/games/{game_id}` to get the air date. If that call fails, show
     the clue without a date.
  3. Add a retry cap and show an error state, instead of looping forever or
     crashing on a `null` response like the current code does.
- Checks applied to each clue:
  - `clue` and `response` are not empty
  - the clue doesn't depend on media (for example "seen here", "(Video Daily Double)", or "Sarah of the Clue Crew")
  - the clue's id isn't in the local "reported" list (Step 4)

### Step 4: The "Report Question" button
cluebase has nowhere to send a report, so we need a choice. Options:
- **A (recommended): Report on the device only.** Save reported clue ids with
  `shared_preferences` and never show those clues again on that device. The UI
  stays the same; only the wording changes from "report" to "hide".
- **B: Remove the button.** This is the simplest option, but it drops a feature.
- **C: Report through GitHub issues.** The button opens a pre-filled issue on
  the cluebase repo or this repo using `url_launcher`.

### Step 5: UI (`lib/quiz_page.dart`)
- Update the import and the repository type.
- Make `_loadQuestion` handle errors, so a failed request doesn't leave the
  screen blank or throw an unhandled `Future` error.
- Wire the report button to the option chosen in Step 4.
- The info overlay (`QuestionOverlay`) keeps showing `rawJson`; it now includes
  the cluebase fields and the game data.

### Step 6: Docs and metadata
- Change "jService (jservice.io)" to "cluebase" in `README.md` and in the
  `pubspec.yaml` description, and credit cluebase.

### Step 7: Tests
- `test/question_test.dart`: build `JeopardyQuestion` from fixture cluebase JSON.
  Cover a missing game, a null value, and a value given as a string.
- `test/question_repository_test.dart`: use a mock API to test the clue
  checks, the local reported list, the retry cap, and what happens when the
  game lookup fails.
- Replace the commented-out template in `test/widget_test.dart` with a smoke
  test that uses a fake repository.

## 5. Risks and open questions
- **Two requests per question** (one for the clue, one for its game): adds a
  little delay. We could load the date after the question is already on screen,
  or cache games by id.
- **Rate limits or downtime:** cluebase is a free, community-run service. Fetch
  clues in batches and keep a small queue so the app makes fewer calls.
- **Old toolchain:** the project still uses Dart 1/early Dart 2 code (`new`,
  `intl ^0.15.6`, `HttpStatus.OK`). This migration doesn't change that, but
  building on a current Flutter SDK will need a separate upgrade (null safety,
  updated dependencies).
- **Decision needed:** which option in Step 4.

## 6. Suggested commit order
1. Add `ClueBaseAPI` and its tests
2. Update the model to read cluebase fields, with tests
3. Switch the repository and UI over, then delete `jservice_api.dart`
4. Rework the report feature
5. Update the README and pubspec
