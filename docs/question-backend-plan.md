# Plan: Pluggable question backend (local database or API)

jservice.io is gone, and the app still calls it directly. The
[local database plan](local-database-plan.md) has already produced the clue
database build (`tool/build_clue_db.py`) and the toolchain upgrade. Its
section 4 assumed the app would read only from the local database, with a
`QuestionSource` interface left as a hook "for later".

This plan makes the choice of backend a built-in feature. The app can read
from the **local SQLite database**, from an **HTTP API**, or from **an API
that falls back to the local database**, and you pick one at build time.
This plan **replaces sections 4 and 6** of the local database plan. Sections
1–3 (the dataset, the build pipeline and the toolchain) stay as they are.

## 0. What the current code tells us

- `JServiceQuestionRepository` (`lib/controller/question_repository.dart`) is
  hard-wired to jService. `JeopardyQuestion.fromJson` assumes jService's JSON
  shape (`category.title`, `airdate`), and the repository loops on jService's
  `invalid_count`.
- `QuizPage` creates its own repository, so tests and other backends have
  no way to swap it out.
- Load errors only go to `debugPrint`, so the screen just stays blank.
- **Release Android builds can't reach the network.** Only the `debug/` and
  `profile/` manifests have `android.permission.INTERNET`; `main/` doesn't.
  Any API backend needs it added. The local plan's idea of dropping
  `INTERNET` is reversed here.
- The old client used plain `http://`. Android 9+ and iOS (ATS) block that by
  default.
- The value and air date are never shown on screen; they only appear in the
  raw-data info overlay.
- The widget tests rely on every HTTP request returning 400 in tests.

**Hosted APIs.** I couldn't check any hosted Jeopardy API from this session,
because outbound network is restricted. Community jService clones come and go,
and depending on one is how the app broke in the first place. So this plan
doesn't depend on any single service. It defines a small API contract of its
own (§7), includes a jService-compatible dialect for clones and self-hosted
copies of jService (§6), and adds a script for serving the local database
yourself (§8).

## 1. Architecture

```
QuizPage ──> QuestionRepository ──> QuestionSource (interface)
                 │                    ├─ LocalQuestionSource      (clues.db via sqflite)
                 │                    ├─ HttpQuestionSource       (+ ApiDialect: quizapp | jservice)
                 │                    └─ FallbackQuestionSource   (primary, fallback)
                 └─> HiddenQuestionStore (user.db, shared by every source)
```

- The **source** knows how to fetch a random question and nothing else.
- The **repository** handles everything that works the same for every
  source: skipping hidden questions, the retry limit, and hiding and reporting.
- `createQuestionSource(config)` in `lib/config/` builds the source from build
  config (§9). `main.dart` passes the repository into `QuizApp` and on to `QuizPage`.

New files:

```
lib/config/source_config.dart          # reads --dart-define values, validates them
lib/config/source_factory.dart         # SourceConfig -> QuestionSource
lib/data/question_source.dart          # interface, QuestionFilter, exceptions
lib/data/local_question_source.dart
lib/data/clue_database.dart            # asset copy and version check (from local plan step 2)
lib/data/http_question_source.dart
lib/data/api_dialect.dart              # ApiDialect, QuizApiDialect, JServiceDialect
lib/data/fallback_question_source.dart
lib/data/hidden_question_store.dart    # user.db
lib/controller/question_repository.dart  # rewritten
tool/serve_clues.py                    # optional self-hosted API (§8)
config/question_source.example.json
```

`lib/model/jservice_api.dart` is deleted. Its behaviour moves into `JServiceDialect`.

## 2. Model (`lib/model/question.dart`)

The model doesn't depend on any source. Parsing moves into each source:
`fromRow` for the local database, and the dialects for APIs.

```dart
class JeopardyQuestion {
  final String sourceId;        // namespace for hidden keys, e.g. 'jwolle1' or 'jservice:host'
  final String key;             // stable within sourceId: clue_key (decimal string) or API id
  final String question;        // the clue text (the app's existing naming)
  final String answer;          // the correct response
  final String category;
  final int? value;             // null when unknown
  final int? round;             // 1, 2, 3; null if the source doesn't say
  final DateTime? airDate;      // nullable: APIs may omit it or send something unparseable
  final int? dailyDoubleWager;
  final String? categoryComment;
  final String? notes;
  final Map<String, Object?> raw; // shown as-is by the info overlay

  bool get isFinalJeopardy => round == 3;
}
```

- Keys are **strings**. `clue_key` is a signed 64-bit integer. That's fine in
  Dart on native platforms, but it isn't safe in JSON for JS-based servers or
  on Flutter web.
- Keep `_sanitizeString` (strip `<i>` and stray backslashes) as a shared
  helper. The API dialects use it, because API data isn't cleaned up front the
  way the build script cleans the local data.
- `formattedDateTime()` returns `''` when `airDate` is null.

## 3. `QuestionSource` interface and the repository

```dart
abstract class QuestionSource {
  String get description;               // shown in errors and the hide dialog
  bool get supportsRemoteReport;
  Future<void> open();                  // copy the DB / no-op; may throw SourceUnavailable
  Future<JeopardyQuestion> randomQuestion({QuestionFilter filter = QuestionFilter.any});
  Future<void> reportRemote(JeopardyQuestion q) async {}
  Future<void> close();
}

class QuestionFilter {               // optional; unused by the UI in v1
  final Set<int>? rounds;
  final DateTime? from, to;
}

class SourceUnavailable implements Exception { final String message; ... }  // network, missing asset, 5xx
class NoQuestionFound  implements Exception { ... }                        // filter or hides used up
```

There are two exception types so that fallback can tell "the backend is down"
(switch to the fallback) apart from "nothing matches" (don't switch).

`QuestionRepository`:
- `open()` opens the source and the `HiddenQuestionStore`.
- `next()` calls `randomQuestion()` up to 20 times, skips any `(sourceId, key)`
  that is hidden, and throws `NoQuestionFound` after that. This replaces the
  `invalid_count` loop.
- `hide(q)` writes to `user.db` first. If the source `supportsRemoteReport`,
  it then calls `reportRemote(q)` without waiting for it and only logs a
  failure, so hiding always works even when the network is down.

## 4. `HiddenQuestionStore` (`user.db`)

```sql
CREATE TABLE hidden (
  source_id    TEXT NOT NULL,
  question_key TEXT NOT NULL,
  hidden_at    TEXT NOT NULL,
  PRIMARY KEY (source_id, question_key)
);
```

- This replaces the local plan's `reported` table. That table declared
  `clue_key TEXT` while the clue database stores it as `INTEGER`; this plan
  always stores the key as a decimal string.
- The store loads everything into a `Set` when it opens (it will only ever
  hold a few hundred rows), so checking whether a question is hidden needs no
  database query.
- **Shared namespace:** the local source and the `quizapp` API dialect both use
  the dataset's namespace (`jwolle1`). That way a clue you hid while connected
  to your self-hosted server stays hidden when the app falls back to the local
  database. jService clones get `jservice:<host>`.

## 5. `LocalQuestionSource`

This is the same as steps 2–3 of the local plan: copy the asset into the app
support folder on first launch, open it read-only, and pick a random id
between 1 and `max(id)`. Changes:

- **Version check without reading the database.** The build script also
  writes `clues.version` (the `meta` rows as JSON) next to `clues.db`. The
  app copies the database again whenever the bundled version file differs
  from the installed one, so any rebuild reaches the app, and launches never
  load the ~87 MB asset just to compare versions. The installed version file
  is deleted before copying and written last, so an interrupted copy is
  redone. A database with an unsupported `schema_version` is refused with a
  "rebuild it" message.

- **The database asset is optional.** `pubspec.yaml` lists the directory
  `assets/db/` instead of the file. A committed `assets/db/.gitkeep` is kept
  out of the ignore rule (`assets/db/*` plus `!assets/db/.gitkeep`). An
  API-only build then compiles without the 43 MB database, and if
  `rootBundle.load` fails, `open()` throws
  `SourceUnavailable('No bundled clue database. Run python3 tool/build_clue_db.py.')`.
- With a filter: `SELECT ... WHERE id >= ?random AND round IN (...) ORDER BY id LIMIT 1`.
  If that finds nothing, try again from `id >= 1`. If it still finds nothing, throw `NoQuestionFound`.
- `sourceId` comes from `meta` (add `dataset_namespace = 'jwolle1'` to the
  build script's `meta` rows). If the key is missing, it defaults to `'jwolle1'`.

## 6. `HttpQuestionSource` and dialects

- Use `package:http` with an injectable `Client`. That makes it testable with
  `MockClient`, and unlike `dart:io`'s `HttpClient` it works on every platform.
- Config: `baseUrl`, `dialect`, an optional bearer `token`, and an 8 s timeout.
- **Prefetching:** it fetches questions in batches of 10 and refills when 3
  or fewer remain, so tapping refresh shows the next question at once and the
  app makes about a tenth as many requests.
- **Error handling:** a timeout, `SocketException`, `ClientException`, any
  non-2xx status or malformed JSON all throw `SourceUnavailable` with a short
  message. Items that fail to parse are dropped one at a time, not the whole batch.

```dart
abstract class ApiDialect {
  Uri randomUri(Uri base, int count, QuestionFilter f);
  List<JeopardyQuestion> parseRandom(Object? json);   // tolerant; skips bad items
  Uri? reportUri(Uri base, JeopardyQuestion q);       // null = no remote reporting
}
```

1. **`QuizApiDialect`** speaks the contract in §7 and supports filters on the
   server side.
2. **`JServiceDialect`** follows the original jService routes:
   `GET /api/random?count=N` (fields `id`, `question`, `answer`, `value`,
   `airdate`, `category.title`, `invalid_count`) and
   `POST /api/invalid?id=…`. It skips items with `invalid_count > 0`, as the
   app does today. jService has no filters, so the repository filters on the
   client side. It works with a self-hosted copy of the open-source jService
   Rails app and with clones that kept its routes.

Supporting another API (cluebase, for example) means adding one
`ApiDialect` class and a test against a saved sample response. **The plan
doesn't set a hosted service as the default**, for the reasons in §0.

## 7. The `quizapp` API contract (v1)

```
GET  {base}/v1/random?count=10[&round=1,2][&from=YYYY-MM-DD][&to=YYYY-MM-DD]
200  {
       "namespace": "jwolle1",
       "questions": [{
         "key": "-4182736451234567", "category": "...", "category_comment": null,
         "clue": "...", "response": "...", "value": 400, "round": 1,
         "dd_wager": 0, "air_date": "2004-03-01", "notes": null
       }]
     }

POST {base}/v1/questions/{key}/report      -> 204   (404/405 = unsupported, ignored)

Optional header: Authorization: Bearer <token>
```

- The field names match the `clues.db` column names, so a server is just a
  simple `SELECT`.
- `count` is capped at 50 by the server. Unknown query parameters are ignored.
  Breaking changes go under `/v2`.

## 8. `tool/serve_clues.py` (optional self-hosting)

A server that uses only the Python standard library (`http.server` and
`sqlite3`). It serves the §7 contract from `assets/db/clues.db`.

- `--db`, `--host` (**default `127.0.0.1`**), `--port 8080`, `--token`.
  Pass `--host 0.0.0.0` to reach it from a phone on the same LAN.
- Reports go into a separate `data/reports.db`, so the clue database stays
  read-only and can be rebuilt freely. (Not next to `clues.db`: everything
  in `assets/db/` is bundled into the app.)
- **Personal use:** the help text and README warn against putting it on the
  public internet, because of the dataset's terms (see the local plan).
- Why bother: an API-only phone build drops about 43 MB from the APK, and one
  server can share hidden clues across devices. It's also the real target for
  checking `HttpQuestionSource` end to end.
- Tests: `tool/test_serve_clues.py` reuses the sample TSV fixture from
  `test_build_clue_db.py`. It checks the response shape, filters, the `count`
  cap, the token check and reporting.

## 9. Choosing the backend

You choose at build time with `--dart-define-from-file`:

```jsonc
// config/question_source.example.json (committed); copy to config/question_source.json (git-ignored)
{
  "QUESTION_SOURCE": "local",          // local | api | api_with_local_fallback
  "QUESTION_API_URL": "",              // e.g. https://clues.example.lan:8080
  "QUESTION_API_DIALECT": "quizapp",   // quizapp | jservice
  "QUESTION_API_TOKEN": ""
}
```

```
flutter run --dart-define-from-file=config/question_source.json
flutter run                      # no file -> local (the default)
```

- `SourceConfig.fromEnvironment()` reads each value with
  `String.fromEnvironment`. A bad value (unknown source, API mode without a
  URL, or `http://` in a release build) produces a `SourceConfig.error`,
  which the app shows on its error screen instead of crashing.
- `api_with_local_fallback` wraps both sources in a `FallbackQuestionSource`.
  When the primary throws `SourceUnavailable`, it serves from the fallback and
  tries the primary again after 60 s. `NoQuestionFound` is passed on, not
  swallowed. It exposes `usingFallback` so the UI can say it's offline.
- The token is compiled into the binary. That's acceptable for a personal
  server token, but it isn't a real secret.
- **Not in v1:** a settings screen for switching backends at runtime. The
  factory makes it easy to add later (persist the choice in a `settings`
  table in `user.db` and rebuild the repository). Build-time config keeps the
  UI unchanged for a single-user app.

## 10. UI changes (`lib/quiz_page.dart` and widgets)

- `QuizPage({required QuestionRepository repository})` takes the repository
  from `QuizApp` instead of creating it.
- There are three states: **loading** (first open or database copy),
  **question**, and **error** (the message from `SourceUnavailable` or
  `NoQuestionFound`, with a **Retry** button). This replaces the silent `debugPrint`.
- "Report Question" becomes **"Hide Question"**. The dialog asks
  "Hide this question?" and, when `supportsRemoteReport` is true, adds
  "It will also be reported to {description}."
- From the local plan: label Final Jeopardy (`isFinalJeopardy`) as "FINAL
  JEOPARDY", and show `categoryComment` under the category when it's present.
- In fallback mode, show a small cloud-off icon in the app bar while
  `usingFallback` is true.
- The info overlay doesn't change; it shows `raw`.

## 11. Platform changes

- **Android:** add `<uses-permission android:name="android.permission.INTERNET"/>`
  to `android/app/src/main/AndroidManifest.xml`. Without it, API mode fails in
  release. Giving local-only builds the permission too is harmless. Add a
  `network_security_config` in the `debug/` source set only, allowing
  cleartext for `serve_clues.py` during development (done as
  `usesCleartextTraffic` in the `debug/` and `profile/` manifests, since a
  network security config can't name IP ranges). Release builds stay
  HTTPS-only.
- **iOS:** add `NSAppTransportSecurity` → `NSAllowsLocalNetworking = true` to
  `ios/Runner/Info.plist` so the app can reach a server on the LAN, plus
  `NSLocalNetworkUsageDescription`, which iOS 14+ shows when asking for
  local network access. Public hosts stay HTTPS-only.

## 12. Tests

| File | Checks |
|---|---|
| `test/question_test.dart` | sanitising; null `airDate` formatting; `isFinalJeopardy` |
| `test/local_question_source_test.dart` | `sqflite_common_ffi` in-memory DB: random pick, filters with wrap-around, `NoQuestionFound`, missing asset → `SourceUnavailable` |
| `test/http_question_source_test.dart` | `MockClient` with saved sample responses for both dialects; batching and refill; timeout, 500 and malformed JSON → `SourceUnavailable`; one bad item skipped; jService `invalid_count` skip; bearer header sent |
| `test/fallback_question_source_test.dart` | switches over on `SourceUnavailable` only; tries the primary again after the cooldown (fake clock); `usingFallback` |
| `test/question_repository_test.dart` | hidden questions skipped; retry limit; `hide` stays local when `reportRemote` throws |
| `test/source_config_test.dart` | defaults; each invalid combination → error |
| `test/widget_test.dart` | rewritten around a fake `QuestionSource`: loading → question, error → Retry, hide flow; it no longer depends on HTTP returning 400 |
| `tool/test_serve_clues.py` | see §8 |

`flutter analyze`, `flutter test` and `python3 -m unittest discover tool` must
pass at every commit. The SessionStart hook already installs everything needed.

## 13. Suggested commit order

1. ~~**Seam, without changing behaviour.**~~ (done) Add the model, `QuestionSource`,
   `QuestionRepository`, `HiddenQuestionStore` and `HttpQuestionSource` +
   `JServiceDialect` (the old client, reshaped). Inject the repository into
   `QuizPage`, delete `jservice_api.dart`, add `http`, `sqflite`,
   `path_provider` and `sqflite_common_ffi` (dev), and write the tests. The app
   behaves exactly as it does today: it still points at jService, which is dead.
2. ~~**Local source (the app works again).**~~ (done) Add `ClueDatabase`,
   `LocalQuestionSource`, the `assets/db/` directory asset, the `dataset_namespace`
   meta row, and `SourceConfig` and the factory, with `local` as the default.
   Because `api` can already be selected, the `INTERNET` permission moved here
   from step 3. Add tests.
3. ~~**API mode.** Add `QuizApiDialect`, `FallbackQuestionSource`, the
   debug network config and the iOS ATS key.~~ (done) Add tests.
4. ~~**Self-hosting.** Add `tool/serve_clues.py` and its tests.~~ (done; also
   `test/serve_clues_contract_test.dart`, which runs the app's HTTP source
   against it)
5. **UI and docs.** Add the error and Retry states, the Hide wording, Final
   Jeopardy and the category comment, and the offline icon. Update the README
   (backend options, config file, self-hosting, personal-use note) and the
   `pubspec.yaml` description. Point sections 4 and 6 of
   `local-database-plan.md` at this plan.

## 14. Risks and open questions

- **API mode is only as good as the server behind it.** No hosted Jeopardy API
  could be checked from this session. Self-hosting (§8) or
  `api_with_local_fallback` are the dependable options.
- **Dataset terms:** `serve_clues.py` has to stay private. Bind it to
  localhost or the LAN, never the public internet.
- **Hidden questions** only carry across sources that share a namespace. A
  jService clone's ids can't be matched to `clue_key`s.
- **APK size:** local mode still adds about 43 MB. An API-only build that
  skips `build_clue_db.py` drops it.
- **Decided:** release builds stay https-only, so `serve_clues.py` (plain
  http) is used from debug or profile builds. For release builds the README
  documents putting HTTPS in front of it (Tailscale serve, or Caddy with a
  domain you own); private certificates don't work, because Android apps
  don't trust user-installed CAs by default.
- **Decided:** build-time config is enough for v1. A runtime backend switcher
  is left for later (§9).
