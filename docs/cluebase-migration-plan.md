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

## 2. The cluebase API

Taken from the cluebase documentation page (© 2019, Luke Lavin).

- Host: `cluebase.lukelav.in`. The docs never give a scheme, so try `https` first
  (see the risks in section 5).
- **Only GET requests are public.** Other HTTP methods need a secret key.
- Every response is wrapped in an envelope:
  - Success: `{"status": "success", "data": [ ... ]}`. `data` is **always a list**,
    even for single-item endpoints like `/clues/{id}` and `/games/{id}`.
  - Failure: `{"status": "failure", "error": "LimitNotANumberError(): ..."}`, with no `data`.
    Errors come back with HTTP 400 (bad query) or 404 (`IdNotFoundError`).
  - The docs say callers must check `status` before reading `data`.
- Endpoints the app needs:
  - `GET /clues/random`: takes `limit` (default 1, **max 100**),
    `category=<str>` (best with large categories like "Science"), and
    `difficulty=<1-5>`
  - `GET /games/{id}`: returns `air_date` in `YYYY-MM-DD` format
- Other endpoints: `/clues` and `/games` (`limit` max 1000, `offset`,
  `order_by`, `sort=asc|desc`), `/clues/{id}`, `/categories` (sorted by
  frequency, `limit` max 2000), `/contestants`, `/contestants/{id}`,
  `/contestants/{first_last}`, `/contestants/random`, `/seasons`, `/uptime`.
- Clue fields: `id` (int), `game_id` (int), `value` (int), `daily_double`
  (bool, **always false**: this wasn't scraped), `round` (`"J!"` or `"DJ!"`;
  **there are no Final Jeopardy clues**), `category` (string), `clue`
  (string), `response` (string).
- Game fields: `id`, `episode_num`, `season_id`, `air_date`, `notes`,
  `contestant1..3`, `winner`, `score1..3`.
- **There is no "invalid" or report endpoint**, and clues have no `invalid_count`.
  For bad data, the docs ask people to email the maintainer.
- The docs warn that IDs aren't sequential, so don't loop through them.

## 3. Field mapping

| `JeopardyQuestion` | jService | cluebase |
| --- | --- | --- |
| `id` | `id` | `id` |
| `question` | `question` | `clue` |
| `answer` | `answer` | `response` |
| `value` | `value` | `value` (always an int) |
| `category` | `category.title` | `category` |
| `airDate` | `airdate` | **not on the clue**: needs `/games/{game_id}` → `data[0].air_date` (`YYYY-MM-DD`, which `DateTime.parse` reads) |
| `rawJson` | whole clue | clue JSON plus a nested `game` object (for the info overlay) |

## 4. Implementation steps

### Step 1: API client
- Add `lib/model/cluebase_api.dart` with a `ClueBaseAPI` class:
  - `Future<List<dynamic>> getRandomClues(int limit, {String category, int difficulty})`
    calls `Uri.https('cluebase.lukelav.in', '/clues/random', {...})`. Check that
    `limit` is 1–100 and `difficulty` is 1–5 before sending.
  - Shared response handling: decode the body **even when the status code isn't 200**.
    If `status != 'success'`, throw a `ClueBaseException` that carries the `error` text.
    Otherwise return `data`.
  - `Future<Map<String, dynamic>> getGame(int id)` calls `/games/{id}` and returns `data[0]`.
  - Let callers pass in the `HttpClient` (default is a shared one) so tests can mock it.
- Delete `lib/model/jservice_api.dart`. (cluebase has no POST endpoint, so `markJServiceQuestionInvalid` goes with it.)
- Use **HTTPS**. jService used `Uri.http`, which Android 9+ blocks by default for cleartext traffic anyway.

### Step 2: Model (`lib/model/question.dart`)
- Replace `fromJson` with a cluebase version, `fromClueBaseJson(clue, {game})`, that uses the mapping above.
- Make `airDate` nullable. `formattedDateTime()` returns `''` when it's missing,
  so the app still shows a question if the game lookup fails.
- Keep `_sanitizeString` (it removes `<i>` tags and backslashes), and check
  whether cluebase text also needs HTML entities (like `&amp;`) decoded.
- Optionally add a `round` field (`J!` or `DJ!`). Ignore `daily_double`, since it's always false.

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
cluebase only accepts GET requests and has nowhere to send a report, so we need a choice. Options:
- **A (recommended): Report on the device only.** Save reported clue ids with
  `shared_preferences` and never show those clues again on that device. The UI
  stays the same; only the wording changes from "report" to "hide".
- **B: Remove the button.** This is the simplest option, but it drops a feature.
- **C: Report outside the app.** After hiding the clue on the device (as in A),
  the button also offers to open a pre-filled issue on this repo, or the email
  address the cluebase docs give for bad data, using `url_launcher`.
  Keep it opt-in so the maintainer doesn't get flooded.

### Step 5: UI (`lib/quiz_page.dart`)
- Update the import and the repository type.
- Make `_loadQuestion` handle errors, so a failed request doesn't leave the
  screen blank or throw an unhandled `Future` error.
- Wire the report button to the option chosen in Step 4.
- Optional later feature: `/clues/random` takes `category` and `difficulty`, so
  we could add pickers (using `/categories` to list categories). This isn't
  needed to replace jService.
- The info overlay (`QuestionOverlay`) keeps showing `rawJson`; it now includes
  the cluebase fields and the game data.

### Step 6: Docs and metadata
- Change "jService (jservice.io)" to "cluebase" in `README.md` and in the
  `pubspec.yaml` description, and credit cluebase.

### Step 7: Tests
- `test/question_test.dart`: build `JeopardyQuestion` from the sample JSON in
  the docs (clue 30000 / game 450), plus a case where the game is missing.
- `test/cluebase_api_test.dart`: unwrap a success envelope, turn a failure
  envelope (400 with `LimitOverMaxError`) into an exception, and reject an
  out-of-range `limit` before sending.
- `test/question_repository_test.dart`: use a mock API to test the clue
  checks, the local reported list, the retry cap, and what happens when the
  game lookup fails.
- Replace the commented-out template in `test/widget_test.dart` with a smoke
  test that uses a fake repository.

## 5. Risks and open questions
- **Two requests per question** (one for the clue, one for its game): adds a
  little delay. We could load the date after the question is already on screen,
  or cache games by id.
- **Is it HTTPS, and is it still running?** The docs are from 2019, have no URL
  scheme, and list no rate limits. Before coding, check that
  `https://cluebase.lukelav.in/uptime` responds (it couldn't be reached from the
  environment this plan was written in). If only HTTP works, add an Android
  `network_security_config` entry and an iOS ATS exception for this one host.
- **Downtime or load:** it's a single-maintainer hobby service. Fetch clues in
  batches (up to 100 per call) and keep a local queue, so each refresh doesn't
  need a network call. A bundled offline set of clues could be a fallback later.
- **Fewer kinds of clues:** cluebase has no Final Jeopardy clues and no
  Daily Double flag. Neither is a problem for this app.
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
