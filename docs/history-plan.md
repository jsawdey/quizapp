# Plan: Score history and all-time statistics, kept on the server

[Score keeping](scoring-plan.md) counts the game being played, but **New
game** erases it and nothing is kept from one game to the next. Its §7 left
"history and all-time statistics" for its own plan "once there's a game
worth tracking". There is one now, and since the [Docker
image](docker-plan.md) the server runs all the time on the NAS. This plan
keeps every answer in **one database on the server**, so the history adds up
everything you play: the web UI on any device, and phone builds wherever
they are.

## 0. What a person can do

- **Play as now.** Each answer still counts in the current game, and it is
  also sent to the server's history. Nothing new to tap.
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
  - and how many answers are still waiting to be sent from this device.
- **Keep one game per device**, as now. A game on the phone and one in the
  browser are separate games; both end up in the history.

## 1. What the code already does

| Code | What history needs from it |
|---|---|
| `ScoreKeeper.show`, `record` and `newGame` (`lib/controller/score_keeper.dart`) | The moment of every result, the question it's for, a change of mind (a second `record` for the same question) and the start of a new game. |
| `Score` and `SharedPrefsScoreStore` | The game's own figures (answered, right, best streak, dollars), already computed by the rules in the scoring plan. The saved JSON gains a game id (§3). |
| `Question` | Everything a statistic groups by: `sourceId`, `key`, `category`, `format`, `round`, `boardRow`, `value`, `dailyDoubleWager`, `difficulty`. |
| `SourceConfig` (`lib/config/source_config.dart`) | Which server the build belongs to: the page's own origin on the web, `QUESTION_API_URL` with the `quizapp` dialect on phones and desktop. |
| `ApiCredentials`, `TokenStore` | The token the server asks for, entered once in the web UI or compiled into a phone build. |
| `serve_clues.py` | The `quizapp` API, the token check and `reports.db`, the pattern for a second database next to the questions. The Docker image keeps everything in `/data`. |
| `HttpQuestionSource._send` | How the app talks to the server: timeout, `Unauthorized` and `SourceUnavailable`. History uses the same rules but its own small client (§4), since it isn't a question source. |

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

**The current game stays on the device**, as the scoring plan decided: the
server holds history, not the live score. The game in progress when this
ships gets an id and appears in the history from its next answer, with its
totals so far; its earlier answers were never recorded one by one.

## 3. The app

**`lib/model/history.dart`**: `HistoryAnswer` and `HistoryGame`, plain
values with `toJson`, built from a `Question` and a result, or from a
`Score`.

**`lib/data/history_queue.dart`**: answers and game rows waiting to be sent.
`SharedPrefsHistoryQueue` keeps them as JSON under `history_queue`, which
works on every platform, the web included. Adding an answer with an id
already queued replaces it (a change of mind before it was sent); a game
row replaces the queued row for that game. Capped at 10,000 answers, oldest
dropped first and logged: about a year of heavy play offline. A queue that
can't be read starts empty, like the saved score.

**`lib/data/history_client.dart`**: `HistoryClient`, with the server's base
URL and the same `ApiCredentials` as the questions:

```dart
class HistoryClient {
  Future<void> send(List<HistoryAnswer> answers, List<HistoryGame> games);
  Future<HistoryStats> stats({required int utcOffset});
}
```

It uses the timeout, `Unauthorized` and `SourceUnavailable` rules of
`HttpQuestionSource._send`, moved to a shared helper both call.

**`lib/controller/history_recorder.dart`**: `HistoryRecorder`, the link
between the keeper, the queue and the client.

- `ScoreKeeper` takes an optional recorder, as `QuizPage` takes an optional
  keeper. `record` calls `recorder.answer(question, right, game)` with the
  answer id made in `show` (kept until the next `show`, so a change of mind
  reuses it), and every change to the score calls `recorder.game(score)`.
  `newGame` makes a new game id. Without a recorder, scoring is exactly as
  now, so the existing tests stand.
- The game id is saved with the score: the JSON gains `"game":"5be1…"`. A
  saved score without one (from before this change) gets one when it's
  read, as does an empty score when its first answer is recorded.
- Everything goes into the queue first. The recorder then sends the queue in
  batches of up to 500, oldest first, removing what the server accepted. It
  sends after each answer (at most one send in flight), when the app starts,
  and after a send fails, again 1 minute later, then 5, then 15. An
  `Unauthorized` reply waits for the token: the web UI already asks for it
  when questions need it.

**Which server.** The recorder exists only when the build has a `quizapp`
server: on the web, always (the page's origin); elsewhere, when
`QUESTION_API_URL` is set and `QUESTION_API_DIALECT` is `quizapp`, whether
the build's source is `api` or `api_with_local_fallback`. That server keeps
the history whichever source the ⇄ button has picked. A build without one
keeps score as now and shows no History button.

**`main.dart`** builds the recorder from `SourceConfig` next to the keeper,
sharing `credentials`.

## 4. The server (`tool/serve_clues.py`)

**`history.db`**, next to `reports.db` (`--history`, default
`data/history.db`, so `/data/history.db` in the container). Like the
reports, it is the server's own data, separate from the question database,
which stays read-only.

```sql
CREATE TABLE answers (
  id TEXT PRIMARY KEY, game TEXT NOT NULL,
  answered_at TEXT NOT NULL, utc_offset INTEGER NOT NULL,
  namespace TEXT NOT NULL, question_key TEXT NOT NULL, category TEXT NOT NULL,
  format TEXT NOT NULL, round INTEGER, board_row INTEGER, value INTEGER,
  daily_double INTEGER, difficulty TEXT, correct INTEGER NOT NULL,
  received_at TEXT NOT NULL);
CREATE INDEX answers_by_time ON answers (answered_at);
CREATE TABLE games (
  id TEXT PRIMARY KEY, started_at TEXT, updated_at TEXT NOT NULL,
  answered INTEGER NOT NULL, correct INTEGER NOT NULL, best INTEGER NOT NULL,
  dollars INTEGER NOT NULL, valued INTEGER NOT NULL);
CREATE TABLE meta (name TEXT PRIMARY KEY, value TEXT NOT NULL);  -- schema_version 1
```

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

**`GET /v1/history/stats?utc_offset=-240`**: everything the History screen
shows, computed in SQL so the app only lays it out:

```json
{"total": {"answered": 1830, "right": 1204},
 "last_30_days": {"answered": 410, "right": 288},
 "last_7_days": {"answered": 96, "right": 70},
 "by_round": [{"round": 1, "answered": 700, "right": 520}, "..."],
 "by_row": [{"row": 1, "answered": 300, "right": 270}, "..."],
 "by_difficulty": [{"difficulty": "easy", "answered": 200, "right": 170}, "..."],
 "strongest": [{"namespace": "jwolle1", "category": "POTENT POTABLES", "answered": 14, "right": 13}],
 "weakest": ["..."],
 "best_streak": 23,
 "recent_games": [{"started_at": "...", "answered": 40, "right": 29, "dollars": 9800}]}
```

The days are counted with `utc_offset` (the one asked with, for "today"),
so they're the player's days. Strongest and weakest are the top and bottom
5 categories by percentage with at least 10 answers, ties going to more
answers. Recent games are the last 10 by `updated_at`.

`/v1/info` gains `"history": true`, so an app talking to an older server
shows no History button and doesn't send.

## 5. UI

**Score dialog:** a **History** action next to New game and Close, shown
when the app has a recorder.

**History screen** (`lib/ui/history_page.dart`): a full page, since it's
more than a dialog holds. It fetches the stats when opened, shows a spinner
until they arrive, and says so plainly if the server can't be reached ("The
history is on <host>, which can't be reached right now") or needs the
token. Sections, each left out when empty:

1. **Overall**: all time, last 30 days, last 7 days, as `1,204/1,830 right
   (66%)`.
2. **Jeopardy! clues**: by round and by row, each a row with a thin bar for
   the percentage.
3. **Trivia**: by difficulty, the same way.
4. **Categories**: strongest and weakest, with their counts.
5. **Games**: best streak ever, and recent games with date, right out of
   answered, best streak and dollars.
6. A footer: "12 answers from this device haven't been sent yet", when the
   queue isn't empty.

Bars, not charts: figures in rows read well at 360 px and need no charting
package. A trend chart can come later from the same data.

## 6. Tests

| File | Checks |
|---|---|
| `tool/test_serve_clues.py` | Upload and upsert by id; a change of mind replaces the answer; an older game row doesn't replace a newer one; validation (`400` naming the field) and the batch limit (`413`); the token guards both routes; stats figures on a known set of answers, including day boundaries under different `utc_offset`s, the 10-answer category minimum, and rounds, rows and difficulties; `history.db` problems reported like `reports.db`'s; `/v1/info` says `history` |
| `test/history_test.dart` | `HistoryAnswer` from clues, trivia, Daily Doubles and Final Jeopardy; JSON |
| `test/history_queue_test.dart` | Replace by id; game rows replace; the cap drops the oldest; unreadable queue starts empty; survives a new queue on the same store |
| `test/history_recorder_test.dart` | Queues before sending; sends in batches and removes what was accepted; keeps everything when the server is down and retries on the backoff; waits after `Unauthorized`; one send in flight |
| `test/score_keeper_test.dart` | With a recorder: a result sends an answer; a change of mind reuses the id; `newGame` makes a new game id; the game id survives a reload; an old saved score gets one |
| `test/serve_clues_contract_test.dart` | The app's client against the real server: send, change of mind, stats |
| `test/widget_test.dart` | History button only with a recorder; the screen's sections from canned stats; unreachable and unauthorized messages; the unsent count |

## 7. Suggested commit order

1. This plan.
2. Server: `history.db`, `POST /v1/history`, `GET /v1/history/stats`,
   `history` in `/v1/info`, `--history`, with tests.
3. App: the model, queue, client and recorder, wired into `ScoreKeeper` and
   `main.dart`, with tests. Answers start reaching the server here.
4. App: the History screen and button, with tests, and a check in Chromium
   against the server in Docker.
5. README: "Score history", and the Docker section's list of what lives in
   `./data`.

## 8. Out of scope

- **Separate players.** Everyone who has the token adds to one history, as
  everyone shares one set of hidden questions. Profiles would need a name
  on each device and a `player` column; adding the column later is a
  one-line migration, so nothing here blocks it.
- **Syncing the current game** between devices (scoring plan §7).
- **Replaying missed questions.** The answers keep each question's
  namespace and key, so a later "play the ones I missed" can be built on
  this, but it needs the server to look questions up by key, including
  ones from Open Trivia Database it never held.
- **Editing or deleting history** from the app. It's one SQLite file on
  the NAS; `sqlite3 data/history.db` can do anything needed.
- **Exporting** (CSV and so on), and charts over time.
- **History for builds without a `quizapp` server.** They keep score as
  now.

## 9. Risks and open questions

- **Clock skew.** `answered_at` comes from the device. A phone with a wrong
  clock files its answers on the wrong day; that's a display problem only,
  and `received_at` records when the server got them.
- **The queue lives in shared_preferences**, which is fine for thousands of
  small entries but not for hundreds of thousands. The cap (§3) bounds it.
- **Two servers, one history.** With clues and trivia served from two
  containers on the same `/data` volume, both write `history.db`. SQLite
  handles that with its own locking at this rate, and the History screen
  shows the same figures from either. On separate volumes they'd keep
  separate histories.
- **Privacy.** The history is a record of what you played and when. It stays
  on your NAS, behind the same token as the questions.
- **Decided:** the server computes the statistics (§4), so the web UI,
  phones and any later client agree, and the app gets a few kilobytes
  instead of every answer.
- **Decided:** the device sends its game's totals rather than skips (§2),
  so the scoring rules stay in one place.
