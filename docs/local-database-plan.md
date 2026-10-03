# Plan: Replace jService with a local clue database

jservice.io has been shut down, so the app can no longer load questions. Instead
of switching to another hosted API (we looked at cluebase), the app will read
clues from a **SQLite database on the device**. The database is built from the
[jwolle1/jeopardy_clue_dataset](https://github.com/jwolle1/jeopardy_clue_dataset)
download. The app then needs no network connection and no outside service.

> **Personal use only.** The dataset README says the data belongs to Jeopardy
> Productions, Inc. and asks that it not be used for public-facing apps or
> products. This app is for personal use, so that's fine. But **don't commit
> the TSV or the generated database to this repository**, and don't publish
> builds that contain it. Each developer builds it locally with the script in Step 2.

## 1. The dataset

Checked against release **v42**, commit
`5a2026f465cfd9f2b80a478bd1993c9a2223befc` (2026-07-24).

- File: `combined_season1-42.tsv` (about 80 MB). It's tab-separated with a
  header row and no CSV-style quoting. SHA-256:
  `e5e336af75210f9ecfdd68201201d9acea269ea6be8d3dc445e98bf31399c2e2`.
- Columns: `round` (`1` Jeopardy, `2` Double Jeopardy, `3` Final Jeopardy),
  `clue_value`, `daily_double_value` (the wager; `0` if it isn't a Daily
  Double), `category`, `comments` (the host's remarks about the category),
  `answer` (**the clue text**), `question` (**the correct response**),
  `air_date` (`YYYY-MM-DD`), `notes`.
  - Watch out: the dataset uses Jeopardy's own naming, so `answer` holds what
    the app calls the *question*, and `question` holds what the app calls the *answer*.
- What's in it:
  - 544,110 clues aired between 1984-09-10 and 2026-07-24
  - 9,354 air dates and 58,088 distinct categories
  - 268,688 Jeopardy clues, 266,144 Double Jeopardy clues and 9,278 Final
    Jeopardy clues (Final Jeopardy rows have `clue_value` `0`)
  - 26,413 Daily Doubles
- Data quirks:
  - About 127,000 rows escape their quotes as `\"`, and about 2,200 rows
    contain `\'`. Remove these backslashes at import time.
  - There are **no clue or game IDs**, so the import script has to create them.
  - The dataset author has already removed most clues that depend on images,
    video or audio. About 200 remain, which the import script filters out.
  - There are also `extra_matches.tsv` (special matches with different round
    numbering, including Triple Jeopardy) and per-season files in `seasons/`.
    Leave them out of the first version.
- Updates: the author publishes a new release each season (v42 = Season 42).
  To update, point the script at the new release and rebuild.

## 2. Build pipeline (on the developer's computer, not in the app)

Add `tool/build_clue_db.py`. It uses only the Python standard library
(`csv`, `sqlite3`, `hashlib`, `urllib`).

1. **Download** the TSV from the pinned commit's raw URL into `data/`, unless
   it's already there. Check the SHA-256 and stop if it doesn't match.
   Command-line flags let you choose a different file or expected hash for a new release.
2. **Read** the file with `csv.DictReader(delimiter='\t', quoting=csv.QUOTE_NONE)`.
3. **Clean** each row: remove `\"` and `\'` escapes and any stray backslashes
   (a handful of typos like `pre\valent`), collapse whitespace, and drop any row
   whose category, clue or response is empty.
   Also drop clues that need a picture, video or audio clip the dataset doesn't
   include (198 in v42). The patterns are deliberately narrow and are tested against
   real clues: "highlighted here", "[Instrumental music plays]", "seen on the
   right", "the tune you're hearing", or a bare "What's this?". Clue Crew stage
   directions are kept, because the spoken clue usually works as text.
   `--keep-media-clues` turns the filter off.
4. **Normalize** into the tables below and write `assets/db/clues.db`. Then
   `VACUUM` it and record the dataset version and row counts in a `meta` table.
   It builds into a temporary file first, so a failed run leaves any existing database untouched.
5. Print a summary (counts by round, number of dropped rows, file size) so
   anyone building it can sanity-check the result.

Schema:

```sql
CREATE TABLE meta       (key TEXT PRIMARY KEY, value TEXT NOT NULL);   -- dataset_version, source_sha256, built_at, schema_version
CREATE TABLE games      (id INTEGER PRIMARY KEY, air_date TEXT NOT NULL UNIQUE);
CREATE TABLE categories (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE clues (
  id           INTEGER PRIMARY KEY,      -- numbered 1..N with no gaps, so a random id can be picked cheaply
  clue_key     INTEGER NOT NULL,         -- first 8 bytes of sha1(air_date|round|value|category|clue); stays the same across rebuilds
  game_id      INTEGER NOT NULL REFERENCES games(id),
  category_id  INTEGER NOT NULL REFERENCES categories(id),
  round        INTEGER NOT NULL,         -- 1, 2, 3
  value        INTEGER NOT NULL,         -- 0 for Final Jeopardy
  dd_wager     INTEGER NOT NULL,         -- 0 if not a Daily Double
  category_comment TEXT,
  clue         TEXT NOT NULL,            -- from the TSV `answer` column
  response     TEXT NOT NULL,            -- from the TSV `question` column
  notes        TEXT
);
CREATE INDEX clues_round ON clues(round);
```

- The full v42 build is **87 MB** (43 MB gzipped, which is roughly how much it
  adds to an APK). The build takes about 15 seconds.
- `clue_key` is a 64-bit integer with no index. A 40-character hex key plus a
  unique index would add about 45 MB, and the app never looks clues up by key.
  The script rejects duplicates itself. The value is part of the key because
  one 2012 category has several clues with identical text.
- `.gitignore`: add `data/` and `assets/db/`.
- Tests: `tool/test_build_clue_db.py` runs the script on a small sample TSV and
  checks the escape cleanup, the swap of `answer`/`question`, that `clue_key`
  stays the same between builds, and the row counts. **(Done.)**

## 3. Flutter toolchain upgrade (prerequisite)

**Status:** the Dart side is done (Flutter 3.47.6 / Dart 3.13.5): null safety,
`intl ^0.20.2`, `flutter_lints`, a clean `flutter analyze`, and widget smoke
tests. The app keeps Material 2 (`useMaterial3: false`), so its look doesn't
change. **Still to do:** regenerate the `android/` and `ios/` folders from the
current `flutter create` template, then put back the Android ID
`com.sawdeydev.jeopardyfun`, the iOS bundle ID `com.sawdeydev.jeopardyFun` and the
label `jeopardy_fun`. The launcher icons are Flutter's defaults, so there's
nothing custom to carry over.

The app still uses early Dart 2 code (`new`, `intl ^0.15.6`,
`HttpStatus.OK`, and no null safety). Current versions of `sqflite` and
`path_provider` require Dart 3, so upgrade first, in its own commit:
- Run on the current stable Flutter, migrate to null safety, and update
  `intl`, the Android Gradle/AGP setup and the iOS project.
- Replace deprecated widgets (`FlatButton` → `TextButton`) and remove `new`.
- This is a separate, mechanical change. Once it's done, the app should build
  and run against jService code that can't reach its server (it will just show
  nothing), before any data changes.

## 4. App changes

### Step 1: Dependencies and assets
- `pubspec.yaml`: add `sqflite` and `path_provider`, and list
  `assets/db/clues.db` as an asset.
- Update the README's build steps:
  `python3 tool/build_clue_db.py && flutter run`.

### Step 2: Opening the database (`lib/data/clue_database.dart`)
- SQLite can't open a database directly from Flutter assets. So on first launch,
  copy `assets/db/clues.db` into the app support folder and open it **read-only**.
- When the bundled `meta.dataset_version` is newer than the installed copy's,
  copy it again. That's how a new season's data reaches the app.
- Keep **user data in a separate database** (`user.db`, read-write), so
  updating the clue database never erases it:
  ```sql
  CREATE TABLE reported (clue_key TEXT PRIMARY KEY, reported_at TEXT NOT NULL);
  ```
  It's keyed by `clue_key`, not `id`, so reports still apply after a rebuild renumbers the clues.

### Step 3: `QuestionSource` interface and local version
- `lib/controller/question_source.dart`: an abstract `QuestionSource` with
  `Future<JeopardyQuestion> randomQuestion()` and `Future<void> report(JeopardyQuestion q)`.
- `LocalQuestionSource` implements it:
  - **Picking a random clue:** pick a random number between 1 and `max(id)`,
    load that row together with its category and game, and skip it if its
    `clue_key` is in `reported` (try again, up to a limit).
    `ORDER BY RANDOM()` would scan about 544k rows on each tap, so don't use it.
  - Optional filters (they fit the same interface later): round,
    including or excluding Final Jeopardy, and a date range.
  - **Reporting:** add the clue to `user.db`'s `reported` table.
- Delete `lib/model/jservice_api.dart`. Rename `JServiceQuestionRepository` to
  `QuestionRepository`, which forwards to a `QuestionSource`. Any future source
  (an API or a downloaded update) then only has to implement the interface.

### Step 4: Model (`lib/model/question.dart`)
- Replace `fromJson` with `JeopardyQuestion.fromRow(Map<String, Object?> row)`.
- Add fields: `clueKey`, `round`, `dailyDoubleWager`, `categoryComment`, `notes`.
- `airDate` is always present now, so `DateTime.parse(air_date)` is safe.
- Remove the backslash handling from `_sanitizeString` (the import script does
  it now). Keep it only if it's still needed, for example for leftover `<i>` tags
  (the dataset has 1 row with HTML-looking content).
- `rawJson` becomes the row map, so the info overlay keeps working without changes.

### Step 5: UI (`lib/quiz_page.dart` and the widgets)
- Point the page at the new `QuestionRepository`. Show a loading state while the
  database is first copied (a few seconds on first launch), and show an error if it fails.
- "Report Question" → `report()`. It stays a one-tap action. Rename the dialog
  text to "Hide this question?", since nothing is sent anywhere now.
- Final Jeopardy (`round == 3`, value `0`): label it "FINAL JEOPARDY" instead of
  showing a dollar value. Show `categoryComment` under the category when it's present.
- Optional: an Android-only switch to drop the `INTERNET` permission from the
  main manifest. It's no longer needed outside debug builds.

### Step 6: Tests
- `test/question_test.dart`: `fromRow` with a regular clue, a Final Jeopardy
  clue and a Daily Double.
- `test/local_question_source_test.dart`: use `sqflite_common_ffi` with a small
  database built in memory, and check that reported clues are never returned,
  that reports survive renumbering (the `clue_key` lookup) and that the retry limit works.
- `test/widget_test.dart`: replace the commented-out template with a smoke test
  that uses a fake `QuestionSource`.

### Step 7: Clean up docs and metadata
- Change "jService (jservice.io)" in `README.md` and `pubspec.yaml`, credit the
  dataset, and add the personal-use note from the top of this plan.

## 5. Risks and trade-offs
- **App size:** about 43 MB compressed in the APK, and about 87 MB on the device
  after the first-launch copy. If that's too much, the script could take a
  `--seasons` flag to build a smaller subset (one season is about 14k clues).
- **Updating the data:** new episodes arrive only when you rebuild and
  reinstall. That's fine for personal use, and each rebuild takes about a minute.
- **Missing episodes:** the dataset author notes that some episodes are missing
  or incomplete. A random quiz app won't notice.
- **Toolchain upgrade:** the Flutter and Dart upgrade (section 3) is the largest
  and least predictable part of the work. Doing it as its own commit keeps
  the data changes easy to review.

## 6. Suggested commit order
1. ~~Add `tool/build_clue_db.py` and its tests, and update `.gitignore`~~ (done)
2. Upgrade the Flutter toolchain and migrate to null safety
3. Add `ClueDatabase`, `QuestionSource`, `LocalQuestionSource` and the updated model, with tests
4. Switch the UI and reporting over, then delete `jservice_api.dart`
5. Update the README and pubspec
