# Plan: Clues and trivia from one server

`serve_clues.py` serves one database: the Jeopardy! clues or the trivia
questions, whichever `--db` (or `QUIZ_DB` in Docker) names. Playing both
today means two servers on two ports, and in a browser it means two
addresses, because the web UI only reads from the server that served the
page. The [Docker plan](docker-plan.md) left this out (§9) as "its own
plan". This is that plan: **one server, several databases, switched in the
app** with the ⇄ button like any other source.

## 0. What a person can do

- **Serve both from one server**: `serve_clues.py --db
  assets/db/clues.db --db assets/db/trivia.db`, or in Docker,
  `QUIZ_DB=/data/clues.db,/data/trivia.db` in `.env`. The first database
  is the default.
- **Switch in the app.** Once the app has reached the server, the ⇄ dialog
  lists each database on it, "Jeopardy! clues" and "Trivia", each described
  as "Your question server (nas)". Choosing one
  switches as choosing Open Trivia Database does today. The choice is kept
  between launches.
- **One token.** The token entered in the page (or compiled into a phone
  build) works for every database on the server.
- **Nothing changes for one database**, or for existing builds: `/v1/...`
  still serves the default database, so an app that doesn't know about
  several sees what it sees today.
- **Point a phone build at one database** without the app knowing about the
  others: `QUESTION_API_URL=http://nas:8080/trivia`. The app already keeps
  a base URL's path (`ApiDialect.endpoint`).

## 1. What the code already does

| Code | What this plan uses |
|---|---|
| `open_store()` in `serve_clues.py` | Opens a `ClueStore` or `TriviaStore` as the database's `meta.dataset_kind` says. Opening two is calling it twice. |
| The reports database | Clue reports go in table `reported` and trivia reports in `reported_trivia`, so both stores can already share one `reports.db`. |
| `GET /v1/info` | Says what the server holds: kind, filters, categories, credit. The app reads it whenever a `quizapp` source opens (`QuizApiDialect.open`), after the token has been accepted. |
| `ApiDialect.endpoint` | Resolves `v1/random` below the base URL's path, so `http://nas:8080/trivia` already asks for `/trivia/v1/random`. |
| `SourceChooser` | Lists the configured source, the bundled databases and the public trivia APIs; the ⇄ dialog switches between them and saves the choice. |
| `QuestionRepository.switchSource` | Keeps hidden questions, the token and the filter across a switch. The filter is kept whole and cut down to what each source supports, so a year range chosen for clues comes back after a spell of trivia. |
| Hidden questions | Keyed by the response's `namespace`, so clues and trivia never mix, whichever URL served them. |
| Scoring | One game covers whatever you play ([scoring plan](scoring-plan.md) §2), so it doesn't care either. |

So the server needs routing, and the app needs a way to learn what the
server holds and offer it.

## 2. One path per database

Each database is served under its own name, and the default under `/v1/`
as now:

```
/v1/...          the default (first) database, as today
/clues/v1/...    clues.db
/trivia/v1/...   trivia.db
```

- **The name is the file's stem**: `clues.db` is `clues`, `trivia.db` is
  `trivia`. It must match `[a-z0-9][a-z0-9_-]*`, must not be `v1`, and must
  be unique; otherwise the server stops with an error saying so, before it
  listens. Renaming the file is the way out. A `NAME=PATH` form isn't
  needed for two files and can come later if a third does.
- **Why paths, not a `?db=` parameter:** a path is a base URL, which every
  part of the app already handles (the report URL, the dev proxy, a reverse
  proxy's prefix). A parameter would have to be threaded through every
  request in every dialect.
- **Routing.** A request goes to a database's API when its first segment is
  that database's name and its second is `v1`. Anything else outside
  `/v1/` still goes to the web UI (with `--web`) or 404. So a database name
  can't hide one of the web build's files, such as `assets/`: only
  `/assets/v1/...` would change, and the web build has no such path.
- **The token** guards every database's API, as it guards `/v1/` today; the
  web UI's files still need none.

## 3. `/v1/info` lists the databases

Every `/v1/info`, at the root and under each name, gains `datasets`:

```json
{
  "namespace": "jwolle1", "kind": "clues", "filters": ["round", "air_date", "row"],
  "count": 543912,
  "datasets": [
    {"name": "clues", "kind": "clues", "count": 543912, "path": "./"},
    {"name": "trivia", "kind": "trivia", "count": 4021, "path": "trivia/"}
  ]
}
```

- **`path` is relative to the base the request used.** From
  `/trivia/v1/info` the same list reads `"../"` and `"./"`. The app resolves
  it against its own base URL, so it works behind a reverse proxy that adds
  a prefix the server never sees, with no "where is the root" logic in the
  app.
- **The default's path is the root**, never `clues/`, so there is one URL
  per database and the app can match it against the URL it was built with.
- **It's always there**, with one entry when there's one database. A
  server without `datasets` is an older one, and the app offers nothing
  more.
- The rest of the response is unchanged, so this is additive v1, like
  `choices` and `info` before it ([question backend plan](question-backend-plan.md)
  §7 is updated to say so).

## 4. Changes to `serve_clues.py`

- **`--db` may be given more than once**, in order; the first is the
  default. `QUIZ_DB` takes a comma-separated list, with spaces around each
  path trimmed. A path that contains a comma has to go in `--db` instead.
  Flags still win over the variable, as a whole.
  With neither, it serves `assets/db/clues.db` alone, as now.
- **`open_stores(paths, reports_path)`** returns the stores by name, in
  order, after the name checks of §2. Each store gets a `name`. Every store
  shares the one `--reports` file, which works as is (§1). A missing or
  unreadable database stops the server at start, as today, so a misspelt
  `QUIZ_DB` shows at once and not on the first switch.
- **`make_handler` and `make_server`** take the stores by name instead of
  one store. The handler picks the store from the path (§2) and builds the
  `datasets` list for `info` from the base the request used (§3).
- **The start-up lines** name every database and its path:

  ```
  Serving 543912 clues on http://0.0.0.0:8080/v1/random (also /clues/v1/random)
  Serving 4021 trivia questions on http://0.0.0.0:8080/trivia/v1/random
  ```

- **The personal-use notice** prints when any database has no open
  licence, which is any time the clues are served.
- The module docstring and `--help` describe the new form; the
  `HEALTHCHECK` keeps asking for the default's `/v1/info`, since every
  database has been opened by the time the server answers.

## 5. The app learns what the server holds

### 5.1 Reading the list

- **`ServerDataset`** (in `question_source.dart`): `name`, `kind`
  (`clues` or `trivia`), `count` and `url`, already resolved.
- **`QuizApiDialect.open`** reads `datasets` and resolves each `path`
  against the base, normalised to end in `/` as `endpoint` does. It drops
  any entry that resolves to another scheme, host or port: the token goes
  to every database the server lists, so a list may only point back at the
  same server. A missing or malformed list is an empty one; it never stops
  the source opening.
- **`QuestionSource.serverDatasets`**, empty by default.
  `HttpQuestionSource` returns its dialect's, and `FallbackQuestionSource`
  its primary's.

### 5.2 Offering it (`SourceChooser`)

- **`learn(List<ServerDataset>)`** turns the list into options, placed
  right after the configured one:
  - id `server:<name>`, label from the kind ("Jeopardy! clues" or
    "Trivia", plus ` (<name>)` when two share a kind), and the detail the
    configured option has today ("Your question server (nas)");
  - an entry whose URL is the configured URL is the configured option
    itself, so it isn't listed twice; it only gives that option its label
    ("Jeopardy! clues" in place of the host, or of "This server" in a
    browser);
  - only when the configured source is a `quizapp` one, and only from
    sources on the configured server, so a public API can never add
    options.
- **Created like the configured source**: the same credentials (the web
  build's shared `ApiCredentials`, or the configured token on a phone), so
  a token entered once applies to every database. With
  `api_with_local_fallback`, a database falls back to the bundled one only
  when their kinds match; trivia never falls back to clues.
- **Saved.** The learned list is kept in shared preferences (key
  `server_datasets`) with the configured URL it came from, and read by
  `SourceChooser.load`, so a saved `server:trivia` is still an option at
  the next launch before the server has been reached. A list saved for
  another URL (a rebuilt app pointing elsewhere) is ignored.
- **A database the server stops serving** stays listed until the next list
  arrives without it. Choosing it meanwhile shows the usual "returned HTTP
  404" error with Retry, and ⇄ to switch back. The option in use is never
  removed under the player; it's gone at the next launch.

### 5.3 When it's learned

`QuizPage` calls `sources.learn(repository.source.serverDatasets)` after a
question loads, which is the first moment the source is known to be open
(and, in a browser, the token accepted). Learning the same list again
changes nothing; a new one updates the ⇄ dialog. No request is added: the
list rides on the `/v1/info` the source already makes.

## 6. Docker and the dev proxy

- **`.env.example`** shows both forms:
  `QUIZ_DB=/data/clues.db,/data/trivia.db`. `compose.yaml` keeps
  `/data/clues.db` as its default, so a NAS without `trivia.db` doesn't
  stop.
- **`web_dev_config.yaml`** forwards `/clues/v1/` and `/trivia/v1/` as well
  as `/v1/`, so `flutter run -d chrome` can switch while developing. Other
  names need their own entry; the file says so.

## 7. Tests

| File | Checks |
|---|---|
| `tool/test_serve_clues.py` | Two databases: `/v1/` is the first; `/clues/v1/` and `/trivia/v1/` serve each; `datasets` and its relative paths from the root and from a name; reports through either path persist and share one `reports.db`; the token guards named paths; `/<name>/` outside `v1` still reaches the web UI; bad, duplicate and `v1` names refused; `QUIZ_DB` split on commas and trimmed, and flags win; the notice when any database is unlicensed |
| `test/api_dialect_test.dart` (quizapp) | `datasets` read and resolved from a root and a named base, and behind a path prefix; entries for other hosts dropped; absent or malformed means none |
| `test/source_choice_test.dart` | Learned options and their order; the configured URL isn't listed twice and gains its label; shared credentials; fallback only for a matching kind; nothing learned from a public API; the saved list restores a saved `server:trivia`, and is ignored for another URL |
| `test/fallback_question_source_test.dart`, `test/http_question_source_test.dart` | `serverDatasets` forwarded |
| `test/widget_test.dart` | After the first question, the ⇄ dialog offers the server's other database, and choosing it loads from it |
| `test/serve_multi_contract_test.dart` (new) | The app's HTTP source against the real `serve_clues.py` with both databases: opens at the root, learns both, switches to trivia by its URL, reports a question there |

`flutter analyze`, `flutter test`, `python3 -m unittest discover tool` and
`flutter build web` must pass at every commit.

## 8. Suggested commit order

1. This plan.
2. **`serve_clues.py`**: several `--db`, named paths, `datasets` in
   `/v1/info`, the `QUIZ_DB` list, start-up lines, and the tool tests.
   Useful on its own: phone builds can already use
   `http://nas:8080/trivia`.
3. **The app**: `ServerDataset`, `QuizApiDialect` and the
   `serverDatasets` getters, `SourceChooser.learn` and the saved list,
   `QuizPage` calling it, plus the Dart tests and the contract test.
4. **Docker, dev proxy and docs**: `.env.example`, `web_dev_config.yaml`,
   the README ("Serving questions from your own computer", "Playing in a
   browser", "Running on a NAS with Docker"), the question backend plan's
   §7 and the Docker plan's §9. Then a manual check in a browser
   (Playwright, `locale: 'en-US'`, as before) against the container with
   both databases: enter the token, play a clue, switch to Trivia with ⇄,
   reload and still get trivia, hide a question, switch back to clues.

Commits 2–3 are the feature.

## 9. Out of scope

- **Mixing clues and trivia in one session**, a question from either at
  random. That's the `MixedQuestionSource` the
  [general trivia plan](general-trivia-plan.md) §10 leaves open; this plan
  makes it easier, since the app will know both URLs, but it's a different
  feature.
- **Listing databases before the token is entered.** `/v1/info` stays
  behind the token, so a browser learns the list after its first question.
  The page asks for the token before anything else anyway.
- **A token per database**, or a database only some devices can see.
- **Serving a folder** of databases, or adding one without a restart.
- **A web page per database** (`/trivia/` opening the app on trivia). The
  root page and ⇄ cover it.
- **Finding servers on the network.** The app still learns about a server
  only from its build settings or the page's address.

## 10. Risks and open questions

- **Old apps** keep working: they never read `datasets` and keep using
  `/v1/`, the default. Old servers keep working with the new app: no
  `datasets`, no new options.
- **The saved list can go stale** (§5.2). The cost is one error screen
  with a way out, and it corrects itself the next time the server is
  reached.
- **Two databases of one kind share a reports table.** Clue keys come from
  the dataset and trivia keys from the question text, so different
  databases don't share keys in practice, and a shared key would only
  mean the same question hidden in both, which is what a player would
  want.
- **The health check only reads the default database.** Every database is
  opened at start (§4), so a missing one stops the container instead of
  failing later; one damaged while running would still pass the check,
  as today.
- **Decided:** Docker's default stays one database, so a NAS that has only
  built `clues.db` keeps starting. Serving both is one line in `.env`.
- **Decided:** `QUIZ_DB` separates paths with commas, not `os.pathsep`.
  A comma is the same on every system and easy to read in `.env`, while
  `os.pathsep` is `:` on Linux and `;` on Windows (where `:` is part of
  every drive letter), so the examples would differ by system. Database
  names can't contain a comma (§2), and in Docker the paths are always
  under `/data`, so only a folder name could. Such a path can still be
  given with `--db`, which needs no separator.
