# Plan: Score history and all-time statistics

[Score keeping](scoring-plan.md) counts the game being played, but **New
game** erases it and nothing is kept from one game to the next. Its §7 left
"history and all-time statistics" for its own plan "once there's a game
worth tracking". There is one now.

Each copy of the app has **one player**: you, on however many devices, and
anyone else who downloads the app runs their own copy for themselves, with
or without a server of their own. So this plan keeps every answer **on the
device**, and, when the build has a server (since the [Docker
image](docker-plan.md), the NAS running all the time), **also in one
database there**, which brings together everything played on every device:
the web UI anywhere, and phone builds wherever they are. The app computes
the statistics itself, from whichever answers it has, so a phone with no
server gets history too, and one that has a server shows it even while the
server is out of reach.

## 0. What a person can do

- **Play as now.** Each answer still counts in the current game, and it is
  also kept in the history. Nothing new to tap.
- **No server needed.** A phone or desktop build without one keeps its own
  history on the device.
- **With a server, every device adds up.** Answers go to the server, and
  each phone or desktop build fetches the answers the others sent, so all
  of them, and the web UI, show the same history. A reinstalled phone gets
  it all back.
- **Play anywhere and lose nothing.** A device that can't reach the server
  (a phone away from home without Tailscale running, the NAS restarting)
  keeps its answers and sends them when it next can. That includes questions
  from Open Trivia Database, The Trivia API or the bundled databases: the
  history is about what you answered, wherever the question came from.
- **See all-time statistics**, from a **History** button in the score
  dialog:
  - right out of answered, as a percentage, for all time, the last 30 days
    and the last 7 days;
  - for Jeopardy! clues, the percentage by round and by board row, and the
    all-time Coryat score per game;
  - for trivia, the percentage by difficulty;
  - your strongest and weakest categories (at least 10 answers each);
  - your best streak ever, and recent games with their scores and dates;
  - and, with a server, when this device last synced with it and how many
    answers are still waiting to be sent.
- **Keep one game per device**, as now. A game on the phone and one in the
  browser are separate games; both end up in the history.

## 1. What the code already does

| Code | What history needs from it |
|---|---|
| `ScoreKeeper.show`, `record` and `newGame` (`lib/controller/score_keeper.dart`) | The moment of every result, the question it's for, a change of mind (a second `record` for the same question) and the start of a new game. |
| `Score` and `SharedPrefsScoreStore` | The game's own figures (answered, right, best streak, dollars), already computed by the rules in the scoring plan. The saved JSON gains a game id (§3). |
| `Question` | Everything a statistic groups by: `sourceId`, `key`, `category`, `format`, `round`, `boardRow`, `value`, `dailyDoubleWager`, `difficulty`. |
| `SourceConfig` (`lib/config/source_config.dart`) | Which server the build belongs to, if any: the page's own origin on the web, `QUESTION_API_URL` with the `quizapp` dialect on phones and desktop. |
| `SqfliteHiddenQuestionStore` | The pattern for a database of the player's own on phones and desktop (`user.db` beside the app's support files), and its shared_preferences counterpart on the web. |
| `ApiCredentials`, `TokenStore` | The token the server asks for, entered once in the web UI or compiled into a phone build. |
| `serve_clues.py` | The `quizapp` API, the token check and `reports.db`, the pattern for a second database next to the questions. The Docker image keeps everything in `/data`. |
| `HttpQuestionSource._send` | How the app talks to the server: timeout, `Unauthorized` and `SourceUnavailable`. History uses the same rules but its own small client (§3), since it isn't a question source. |

Nothing records individual answers today: `Score` holds totals only.

## 2. What is recorded

**An answer**: one row per scored question.

| Field | Example | Why |
|---|---|---|
| `id` | `"9f2c…"`, 32 hex characters | Made on the device when the question gets its first result. A change of mind sends the same id with the new result, and sending again after a lost reply does no harm. |
| `game` | `"5be1…"` | The game it counted in (below). |
| `answered_at` | `"2026-10-13T18:35:10Z"` | UTC. |
| `utc_offset` | `-240` | Minutes from UTC on the device at the time, so "the last 7 days" and "per day" mean your days, whatever time zone the server runs in. |
| `namespace`, `key` | `"jwolle1"`, `"4357…"` | Which question. Lets a later feature find questions you missed. |
| `category` | `"BIOGRAPHIES"` | Strongest and weakest categories, within a namespace. |
| `format` | `"open"`, `"multiple_choice"`, `"true_false"` | Self-reported or picked. |
| `round`, `row`, `value`, `daily_double` | `2`, `3`, `1200`, `false` | Clue statistics; null for trivia. |
| `difficulty` | `"hard"` | Trivia statistics; null for clues. |
| `right` | `true` | The result. |

**A game**: one row per game, with the device's own `Score` figures:
`id`, `started_at`, `updated_at`, `answered`, `right`, `best`, `dollars`,
`valued`. The device already computes these with the scoring rules
(streaks broken by skips, Coryat with Daily Doubles); recomputing them on
the server would mean sending skips too and writing the rules twice. The
row is replaced each time the game changes.

**Skips aren't sent.** They only matter to the streak, which the game row
carries.

**The current game stays on the device**, as the scoring plan decided:
history is finished answers and game totals, not the live score. The game in progress when this
ships gets an id and appears in the history from its next answer, with its
totals so far; its earlier answers were never recorded one by one.

## 3. The app

**`lib/model/history.dart`**: `HistoryAnswer` and `HistoryGame`, plain
values with `toJson` and `fromJson`, built from a `Question` and a result,
or from a `Score`.

**`lib/model/history_stats.dart`**: `HistoryStats.compute(answers, games,
now)`, plain Dart and the only place the statistics are worked out, so
every platform shows the same figures:

- right out of answered for all time, and for the last 30 and 7 days,
  counting each answer's day by its own `utc_offset`, so they're the days
  you played them;
- by round and by board row (clues), and by difficulty (trivia);
- strongest and weakest categories: the top and bottom 5 by percentage,
  grouped within a namespace, with at least 10 answers, ties going to more
  answers;
- the best streak, the highest `best` of any game;
- recent games: the last 10 by `updated_at`.

**`lib/data/history_store.dart`**: where the device keeps history.

```dart
abstract class HistoryStore {
  Future<void> putAnswer(HistoryAnswer answer);   // replaces one with the same id
  Future<void> putGame(HistoryGame game);         // replaces an older row for the game
  Future<HistorySnapshot> all();                  // every answer and game it holds
  Future<HistoryBatch> unsent({int limit = 500});
  Future<void> markSent(HistoryBatch batch);
  Future<int> unsentCount();
  Future<void> merge(List<HistoryAnswer> answers, List<HistoryGame> games, int cursor);
  Future<int> cursor();                           // how far it has fetched from the server
}
```

- **`SqfliteHistoryStore`** (phones and desktop): its own `history.db`
  beside `user.db`, with `answers` and `games` tables shaped like the
  server's (§4) plus a `sent` flag, kept for good. A few MB a year of heavy
  play. Separate from `user.db`, so the two stores never have to agree on a
  schema version.
- **`SharedPrefsHistoryStore`** (the web): only what's waiting to be sent,
  as JSON under `history_queue`, capped at 10,000 answers (oldest dropped
  first and logged). Its `all()` is empty: a web build is always served by
  its server, which holds the history, so the History screen fetches it
  from there (§5).
- `InMemoryHistoryStore` for tests.

**`lib/data/history_client.dart`**: `HistoryClient`, with the server's base
URL and the same `ApiCredentials` as the questions:

```dart
class HistoryClient {
  Future<void> send(HistoryBatch batch);
  Future<HistoryPage> fetch({required int after, int limit = 1000});
}
```

It uses the timeout, `Unauthorized` and `SourceUnavailable` rules of
`HttpQuestionSource._send`, moved to a shared helper both call.

**`lib/controller/history_recorder.dart`**: `HistoryRecorder`, the link
between the keeper, the store and, if there is one, the server.

- `ScoreKeeper` takes an optional recorder, as `QuizPage` takes an optional
  keeper. `record` calls `recorder.answer(question, right, game)` with the
  answer id made in `show` (kept until the next `show`, so a change of mind
  reuses it), and every change to the score calls `recorder.game(score)`.
  `newGame` makes a new game id. Without a recorder, scoring is exactly as
  now, so the existing tests stand.
- The game id is saved with the score: the JSON gains `"game":"5be1…"`. A
  saved score without one (from before this change) gets one when it's
  read, as does an empty score when its first answer is recorded.
- Everything goes into the store first. With a server, the recorder then
  **syncs**: it sends what's unsent in batches of up to 500, oldest first,
  marking what the server accepted, then fetches what the server has
  beyond the store's cursor and merges it. It syncs after each answer (at
  most one sync in flight), when the app starts and when the History screen
  opens, and after a failure, again 1 minute later, then 5, then 15. An
  `Unauthorized` reply waits for the token: the web UI already asks for it
  when questions need it. The web build only sends; it has nothing to merge
  into.

**Which server.** On the web, always the page's origin. Elsewhere, the
build's `QUESTION_API_URL` when `QUESTION_API_DIALECT` is `quizapp`,
whether its source is `api` or `api_with_local_fallback`, and only once
`/v1/info` says the server keeps history (§4). That server keeps the
history whichever source the ⇄ button has picked. A phone or desktop build
without one keeps its history on the device only.

**`main.dart`** builds the store and the recorder next to the keeper,
sharing `credentials`.

## 4. The server (`tool/serve_clues.py`)

**`history.db`**, next to `reports.db` (`--history`, default
`data/history.db`, so `/data/history.db` in the container). Like the
reports, it is the server's own data, separate from the question database,
which stays read-only.

```sql
CREATE TABLE answers (
  id TEXT PRIMARY KEY, seq INTEGER NOT NULL UNIQUE, game TEXT NOT NULL,
  answered_at TEXT NOT NULL, utc_offset INTEGER NOT NULL,
  namespace TEXT NOT NULL, question_key TEXT NOT NULL, category TEXT NOT NULL,
  format TEXT NOT NULL, round INTEGER, board_row INTEGER, value INTEGER,
  daily_double INTEGER, difficulty TEXT, correct INTEGER NOT NULL,
  received_at TEXT NOT NULL);
CREATE TABLE games (
  id TEXT PRIMARY KEY, seq INTEGER NOT NULL UNIQUE,
  started_at TEXT, updated_at TEXT NOT NULL,
  answered INTEGER NOT NULL, correct INTEGER NOT NULL, best INTEGER NOT NULL,
  dollars INTEGER NOT NULL, valued INTEGER NOT NULL);
CREATE TABLE meta (name TEXT PRIMARY KEY, value TEXT NOT NULL);  -- schema_version, last_seq
```

`seq` is a change counter shared by both tables: every row inserted or
replaced gets the next number, so "everything after 1830" is every change a
device hasn't fetched yet.

The columns `question_key`, `board_row` and `correct` are the JSON's `key`,
`row` and `right`, renamed because those are SQL keywords.

**`POST /v1/history`**, with the token like the rest of `/v1/`:

```json
{"answers": [{"id": "9f2c…", "game": "5be1…", "answered_at": "2026-10-13T18:35:10Z", "...": "..."}],
 "games": [{"id": "5be1…", "answered": 10, "right": 7, "...": "..."}]}
```

Upserts each answer and game by id, in one transaction, and answers `204`.
A game row only replaces one with an older `updated_at`, so a slow device
can't overwrite a newer total. Anything malformed is `400` for the whole
batch, with the first problem named; more than 500 answers is `413`. Each
field is checked against §2 (lengths, known formats, rounds 1 to 3, rows 1
to 5), so a bad client can't fill the database with junk.

**`GET /v1/history?after=1830&limit=1000`**: the answers and games
changed after that `seq`, in `seq` order, at most `limit` rows (default and
maximum 1,000):

```json
{"answers": [{"id": "9f2c…", "...": "..."}],
 "games": [{"id": "5be1…", "...": "..."}],
 "next": 2830, "more": true}
```

The device stores `next` as its cursor and asks again while `more` is true.
The server only stores and hands back what devices send; it computes no
statistics, so it needs no change when the History screen gains one.

`/v1/info` gains `"history": true`, so an app talking to an older server
keeps its history on the device and doesn't send.

## 5. UI

**Score dialog:** a **History** action next to New game and Close, shown
when the app has a recorder: every phone and desktop build, and web builds
whose server keeps history.

**History screen** (`lib/ui/history_page.dart`): a full page, since it's
more than a dialog holds. It works out the statistics with
`HistoryStats.compute`:

- **Phones and desktop** show the device's history at once, start a sync,
  and recompute when it brings anything new. A sync that fails leaves the
  figures as they were, with a line saying so.
- **The web** fetches the whole history from its server (in pages, as
  above) and computes from that, with a spinner until it arrives. If the
  server can't be reached it says so plainly ("The history is on <host>,
  which can't be reached right now"), and asks for the token if needed.

Sections, each left out when empty:

1. **Overall**: all time, last 30 days, last 7 days, as `1,204/1,830 right
   (66%)`.
2. **Jeopardy! clues**: by round and by row, each a row with a thin bar for
   the percentage.
3. **Trivia**: by difficulty, the same way.
4. **Categories**: strongest and weakest, with their counts.
5. **Games**: best streak ever, and recent games with date, right out of
   answered, best streak and dollars.
6. With a server, a footer: "Synced with <host> 2 minutes ago", plus "12
   answers from this device haven't been sent yet" when that's so.

Bars, not charts: figures in rows read well at 360 px and need no charting
package. A trend chart can come later from the same data.

## 6. Tests

| File | Checks |
|---|---|
| `tool/test_serve_clues.py` | Upload and upsert by id; a change of mind replaces the answer and gets a new `seq`; an older game row doesn't replace a newer one; validation (`400` naming the field) and the batch limit (`413`); fetching after a cursor, paging with `more`, and fetching everything from 0; the token guards both routes; `history.db` problems reported like `reports.db`'s; `/v1/info` says `history` |
| `test/history_test.dart` | `HistoryAnswer` from clues, trivia, Daily Doubles and Final Jeopardy; JSON round trip |
| `test/history_stats_test.dart` | Each figure on a known set of answers and games, including day boundaries under different `utc_offset`s, the 10-answer category minimum and its tie rule, categories with the same name in two namespaces, and an empty history |
| `test/history_store_test.dart` | Both stores: replace by id; game rows replace only older ones; unsent and mark sent; merge and the cursor; the web store's cap drops the oldest; an unreadable web queue starts empty; the sqflite store survives reopening (through `sqflite_common_ffi`, as the hidden store's tests do) |
| `test/history_recorder_test.dart` | Stores before sending; no server, no sync; sends in batches and marks what was accepted; fetches until `more` is false and merges; keeps everything when the server is down and retries on the backoff; waits after `Unauthorized`; one sync in flight; an older server without `history` gets nothing sent |
| `test/score_keeper_test.dart` | With a recorder: a result records an answer; a change of mind reuses the id; `newGame` makes a new game id; the game id survives a reload; an old saved score gets one |
| `test/serve_clues_contract_test.dart` | The app's client against the real server: send, change of mind, fetch and page |
| `test/widget_test.dart` | History button with a recorder only; the screen's sections from a canned history; a sync that brings new answers updates the figures; unreachable and unauthorized messages on the web; the sync footer |

## 7. Suggested commit order

1. This plan.
2. Server: `history.db`, `POST /v1/history`, `GET /v1/history`, `history`
   in `/v1/info`, `--history`, with tests.
3. App: the model, `HistoryStats` and the stores, with tests.
4. App: the client and recorder, wired into `ScoreKeeper` and `main.dart`,
   with tests. Answers start reaching the device's store and the server
   here.
5. App: the History screen and button, with tests, and a check in Chromium
   against the server in Docker, and on Linux desktop with and without a
   server.
6. README: "Score history", and the Docker section's list of what lives in
   `./data`.

## 8. Out of scope

- **Several players on one copy.** Each copy of the app, with its server if
  it has one, has one player; other people run their own. Everyone who has
  a server's token adds to its one history, as they share its hidden
  questions. Profiles would need a name on each device and a `player`
  column, a one-line migration, so nothing here blocks them.
- **Syncing the current game** between devices (scoring plan §7).
- **Replaying missed questions.** The answers keep each question's
  namespace and key, so a later "play the ones I missed" can be built on
  this, but it needs the server to look questions up by key, including
  ones from Open Trivia Database it never held.
- **Editing or deleting history** from the app. It's one SQLite file on
  the NAS, and one on each device; deleting a row on the server doesn't
  reach the devices that already fetched it.
- **Exporting** (CSV and so on), and charts over time.
- **Syncing between devices without a server**, such as phone to phone.

## 9. Risks and open questions

- **Clock skew.** `answered_at` comes from the device. A phone with a wrong
  clock files its answers on the wrong day; that's a display problem only,
  and `received_at` records when the server got them.
- **The web queue lives in shared_preferences**, which is fine for
  thousands of small entries but not for hundreds of thousands. The cap
  (§3) bounds it.
- **The web fetches the whole history** each time the History screen
  opens: about 150 bytes an answer, so roughly 3 MB for 20,000 answers, a
  heavy year. Fine on a LAN or tailnet; if it grows slow, the web store can
  cache what it fetched, as the phone store does.
- **Two servers, one history.** With clues and trivia served from two
  containers on the same `/data` volume, both write `history.db`. SQLite
  handles that with its own locking at this rate, and the History screen
  shows the same figures from either. On separate volumes they'd keep
  separate histories.
- **Privacy.** The history is a record of what you played and when. It stays
  on your devices and your NAS, behind the same token as the questions.
- **Decided:** the app computes the statistics (§3), not the server. That's
  one implementation for every case: a device with no server, a device
  whose server is out of reach, and the web. The server only stores and
  syncs.
- **Decided:** the device sends its game's totals rather than skips (§2),
  so the scoring rules stay in one place.
