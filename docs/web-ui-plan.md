# Plan: Web UI (the app in a browser, served by `serve_clues.py`)

The [question backend plan](question-backend-plan.md) is done. The app reads
from the local clue database, an HTTP API, or an API with a local fallback,
and `tool/serve_clues.py` serves the database over the `quizapp` API. This
plan adds a **web UI**: the same Flutter app, built for the browser and served
by `serve_clues.py`, so any device on your network can play by opening
`http://<computer>:8080/`, with nothing to install.

## 0. Why this feature next

Candidates for the next feature, roughly in order of value:

| Feature | Value | Cost now |
|---|---|---|
| **Web UI** | Every device on the network (laptops, iPhones without Xcode, a TV browser) can play. One server feeds all of them. | Low: the API, the server and string keys already exist (§1). |
| Round and date filters | `QuestionFilter` is implemented end to end but has no UI. | Low, but it's UI work. Doing it after the web UI means it ships to both at once. |
| Score keeping / "did you get it?" | Makes it a game, not a flash card. | Medium; also UI work. |
| Runtime backend settings | Switch sources without rebuilding. | Medium; the web UI needs a slice of it anyway (the token prompt, §4). |

The web UI goes first. You've asked for it, and the existing architecture
already covers most of it. Every UI feature after it (filters first) then
lands on phones and the browser in one change. Writing a separate HTML/JS
frontend instead would mean building every later feature twice.

## 1. What the current code tells us

I checked this with a trial `flutter create --platforms=web .` and
`flutter build web` in a scratch copy (Flutter 3.47.6):

- **It compiles.** `dart:io` in `clue_database.dart` builds for the web
  because nothing on that path runs there.
- **It fails at startup.** `main.dart` always builds a
  `SqfliteHiddenQuestionStore`. sqflite has no web implementation and
  `path_provider` has no application support directory there, so
  `QuestionRepository.open()` throws and the page shows "Something went wrong
  loading a question." The default source is `local`, which can't work in a
  browser either.
- **The clue database would be published.** `pubspec.yaml` bundles all of
  `assets/db/`. With a built database present, `flutter build web` copies
  `clues.db` (~87 MB) into `build/web/assets/`, where anyone who can load the
  page can download it. That wastes space, and it publishes the whole dataset
  when the dataset's terms forbid public-facing use. Flutter's
  `platforms:` key on an asset entry fixes this. I checked that
  `platforms: [android, ios, linux, macos, windows]` leaves the database out of
  `build/web`.
- **Things that already work on the web:** `package:http` (it uses `fetch` in
  the browser), string question keys (the backend plan chose them partly so
  64-bit keys survive JavaScript), the `quizapp` dialect, and the bundled
  fonts.
- **The https check in `SourceConfig` is wrong for the web.** A release web
  build rejects `http://` URLs, but on the web the browser enforces
  mixed-content rules itself. A page loaded over http from a LAN server must
  be able to call that same server.
- **A compiled-in token protects nothing on the web.** If `serve_clues.py`
  serves both the page and the API, anyone who can load the page can read
  the token in `main.dart.js`.
- **Size:** `build/web` is 40 MB on disk, but a browser downloads one
  renderer (CanvasKit or Skwasm, ~7 MB) plus `main.dart.js` (2.2 MB) and
  caches them. That's fine on a LAN.
- **A default web build needs internet access.** Found while building it:
  `flutter build web` loads CanvasKit from `www.gstatic.com` and the Roboto
  font from `fonts.gstatic.com`, so on a network without internet access the
  page never starts. `flutter build web --no-web-resources-cdn` bundles both
  into `build/web`, and `serve_clues.py --web` warns about builds made
  without it (§6).
- **The development loop:** `flutter run -d chrome` serves the app from its
  own port, which is a different origin from `serve_clues.py`. Flutter's
  `web_dev_config.yaml` supports `proxy:` rules (this Flutter version has
  them), so `/v1/` can be proxied to `localhost:8080` without adding CORS to
  the server.

## 2. Architecture

```
Browser ──GET /──────────────> serve_clues.py --web build/web   (static files, no token)
   │                                │
   └──GET /v1/random, POST report─> │ (bearer token if --token)  ──> clues.db, reports.db
```

On the web, the app talks to the server that served the page:

```
main.dart
 ├─ kIsWeb ? SharedPrefsHiddenQuestionStore : SqfliteHiddenQuestionStore
 ├─ kIsWeb ? token from TokenStore (localStorage) : QUESTION_API_TOKEN
 └─ questionSourceFromEnvironment(pageUrl: Uri.base)  → HttpQuestionSource(quizapp)
```

There are no new sources or dialects. The changes are config defaults, one
storage class, a token prompt, a few UI changes for the browser, and static
file serving in `serve_clues.py`.

## 3. Config on the web (`lib/config/source_config.dart`)

`SourceConfig.parse` gains `bool isWeb = false` and `Uri? pageUrl`.
`fromEnvironment()` passes `kIsWeb` and `Uri.base`. On the web:

- `QUESTION_SOURCE` defaults to `api`. `local` and `api_with_local_fallback`
  are a `SourceConfigError`: "The clue database isn't available in the
  browser; serve it with tool/serve_clues.py".
- `QUESTION_API_URL` defaults to the page's origin (`pageUrl` with path `/`,
  no query or fragment). A different origin is allowed but needs CORS on the
  server, which `serve_clues.py` doesn't provide. The README says so.
- `QUESTION_API_DIALECT` defaults to `quizapp`.
- `http` is allowed in every build mode, because the browser enforces mixed
  content.
- Setting `QUESTION_API_TOKEN` is a `SourceConfigError` ("on the web, enter
  the token in the page instead") because it would ship in plain text to
  every visitor (§4).

So `flutter build web` with no `--dart-define`s produces a build that just
works when `serve_clues.py` serves it.

## 4. The access token on the web

The token can't be compiled in, so the page asks for it:

- `HttpQuestionSource` maps HTTP 401 and 403 to a new
  `Unauthorized extends SourceUnavailable` with the message "The server
  rejected the access token". Because it is a subclass, fallback still treats
  it as "server unavailable". Phones also get a clearer message than
  "returned HTTP 401".
- `HttpQuestionSource.token` becomes settable through a small
  `ApiCredentials` holder that the factory passes in and every request reads.
- `TokenStore` (`lib/data/token_store.dart`) wraps `shared_preferences`
  (localStorage on the web) with `read` and `write`. It is only used on the
  web.
- `QuestionRepository` gets `bool get canSetToken` (true on the web) and
  `Future<void> setToken(String token)`, which saves the token and updates
  the credentials. (As built, the source's buffer isn't cleared: questions
  fetched with an earlier token are still good.)
- `QuizPage`: when `next()` throws `Unauthorized` and `canSetToken` is true,
  the error panel shows a password field and **Connect** instead of
  **Retry**. A rejected token comes back to the same panel with "That token
  was rejected."
- The static files need no token. They contain no clue data, and a browser
  can't add a bearer header to a page load. The API keeps requiring the
  token.

## 5. Hidden questions on the web (`lib/data/hidden_question_store.dart`)

Add `SharedPrefsHiddenQuestionStore`. It keeps a string list under
`hidden_questions`, using the same `sourceId\0key` ids as the other stores,
and loads everything into a `Set` when it opens, like the sqflite store.
`main.dart` uses it when `kIsWeb`.

With the `quizapp` API, hiding a question also reports it to the server, and
the server never serves a reported clue again. The local store is mainly
there so hiding works instantly and offline, as on phones.

## 6. `serve_clues.py --web DIR`

- A new option, `--web DIR`, serves a Flutter web build. It is off by
  default. On startup it checks that `DIR/index.html` exists, or exits with
  "run flutter build web first".
- **Routing:** `/v1/...` goes to the API, as today. Any other `GET` or `HEAD`
  serves a static file, and `/` serves `index.html`. The token check moves
  after routing, so it only applies to `/v1/`.
- **Path safety:** resolve `(root / path).resolve()` and require
  `is_relative_to(root)`. Anything else gets a 404, as do directories and
  dotfiles.
- **Content types:** `mimetypes.guess_type`, plus explicit entries for
  `.wasm` → `application/wasm` (needed for streaming compile, and missing
  from some Pythons), `.mjs`, `.otf`/`.ttf` and `.json`.
- **Caching:** send `Cache-Control: no-cache` everywhere, so the browser
  revalidates and a rebuild shows up on reload. Add `Last-Modified` and
  answer `If-Modified-Since` with 304, so a reload doesn't download 9 MB
  again.
- The startup line prints `Web UI on http://host:port/` when `--web` is set.
- The personal-use warning stays. Nothing about the web UI makes public
  hosting acceptable, and README says not to put `build/web` on GitHub Pages
  or similar (it would need a public API anyway).

## 7. Development loop

Commit `web_dev_config.yaml`:

```yaml
server:
  proxy:
    - target: http://localhost:8080/
      prefix: /v1/
```

Then `python3 tool/serve_clues.py` in one terminal and
`flutter run -d chrome` in another gives hot reload against real data,
same-origin, with no CORS. (If you start the server with `--token`, the page
asks for it, as in §4.)

## 8. UI changes for the browser

These are small, and they help phones and tablets too:

- **Wide screens:** center the board with `ConstrainedBox(maxWidth: 900)` and
  keep the category, clue and button rows in proportion, so a 1920 px window
  doesn't stretch the clue panel into a strip. The existing text scaling
  handles the rest.
- **Keyboard:** Space or Enter flips between clue and response, N or → loads
  the next question, and H opens the hide dialog. Use `Shortcuts` and
  `Actions` on the page, ignored while a dialog or the token field has focus.
  The FAB's tooltip lists the keys in browsers and on desktops. As built,
  the actions are disabled while no question is showing, so the keys aren't
  handled and reach the token field (a handled key never gets to a text box
  in the browser). The page takes focus back after the token is accepted,
  because the browser drops it along with the field.
- **Mouse:** a click cursor on the clue panel.
- **Tab title and metadata:** `web/index.html` and `manifest.json` get the app
  name (`MaterialApp.title`; see §12) and the existing launcher icon. With
  the manifest, "Add to Home Screen" on iOS and Android gives an app-like
  shortcut. (As built, the web icons are the template's: the Android and iOS
  launcher icons are still Flutter's default too.)
- The info overlay and the offline icon are unchanged. The offline icon never
  appears on the web, because there is no fallback there.

## 9. Platform and build files

- Run `flutter create --platforms=web .` and commit `web/` (`index.html`,
  `manifest.json`, `favicon.png`, `icons/`). Check `.metadata` and
  `.gitignore` changes from the template and keep only what's needed.
- `pubspec.yaml`:
  ```yaml
  assets:
    - path: assets/db/
      platforms: [android, ios, linux, macos, windows]
  ```
  plus `shared_preferences`.
- README: a "Web UI" section covering `flutter build web`,
  `python3 tool/serve_clues.py --host 0.0.0.0 --web build/web`, opening
  `http://<computer>:8080/`, the token prompt, the dev loop (§7) and the
  personal-use note. Tailscale `serve` (already in the README) gives the web
  UI https too.

## 10. Tests

| File | Checks |
|---|---|
| `test/source_config_test.dart` | web defaults (api, page origin, quizapp); `local`/fallback rejected on web; http allowed on web in release; token define rejected on web; non-web behaviour unchanged |
| `test/hidden_question_store_test.dart` | `SharedPrefsHiddenQuestionStore` with `SharedPreferences.setMockInitialValues`: hide, survives reopen, shared ids |
| `test/http_question_source_test.dart` | 401/403 → `Unauthorized`; a token change applies to the next request |
| `test/question_repository_test.dart` | `setToken` saves, updates credentials, and the next `next()` succeeds |
| `test/widget_test.dart` | `Unauthorized` → token panel → Connect → question; rejected token message; keyboard shortcuts (space flips, N loads, H opens dialog); wide-window layout is constrained |
| `tool/test_serve_clues.py` | `--web`: `/` serves `index.html`; content types incl. `.wasm`; `../` and encoded traversal → 404; static files need no token while `/v1/` still does; 304 on `If-Modified-Since`; missing `index.html` exits with a message |
| `test/serve_clues_contract_test.dart` | unchanged; still passes after the token check moves |

Manual check (not automated, because Flutter web draws to a canvas and the
clue text isn't in the DOM): build the database with the test fixture,
`flutter build web`, `serve_clues.py --web build/web --token x`, then load it
in the pre-installed Chromium with Playwright, take a screenshot of the token
panel, enter the token, take a screenshot of a clue, press Space, take a
screenshot of the response.

`flutter analyze`, `flutter test`, `python3 -m unittest discover tool` and
`flutter build web` must pass at every commit.

## 11. Suggested commit order

1. ~~**Keep the database out of web builds.** Add the `platforms:` asset entry.
   This is worth doing even if the rest slips: it stops the dataset from ever
   landing in a web bundle.~~ (done)
2. ~~**Web platform and config.** `flutter create --platforms=web .`, the
   `SourceConfig` web defaults and checks, `SharedPrefsHiddenQuestionStore`,
   and the `kIsWeb` wiring in `main.dart`, plus tests. Afterwards
   `flutter run -d chrome` works against a server without a token.~~ (done;
   the `index.html`/manifest metadata came here, with the new files)
3. ~~**Serve it.** `serve_clues.py --web`, the token check after routing,
   `web_dev_config.yaml` and the tool tests.~~ (done; also the warning about
   builds that load from Google's CDN, and HEAD requests. The dev proxy was
   checked with `flutter run -d web-server`: it forwards `/v1/` and the
   `Authorization` header.)
4. ~~**Token prompt.** `Unauthorized`, `ApiCredentials`, `TokenStore`,
   `setToken` and the token panel, plus tests.~~ (done)
5. ~~**Browser polish and docs.** Wide-screen layout, keyboard shortcuts,
   cursor, `index.html`/manifest metadata, the README section and the manual
   Playwright check.~~ (done. The Playwright check, against a
   `--no-web-resources-cdn` build in Chromium with Google's servers
   unreachable, covered: the token panel, a rejected token, a token containing
   N, H and a space, a reload using the saved token, Space/N/H after
   connecting, and the 900 px board in a 1920 px window.)

## 12. Risks and open questions

- **Dataset terms.** The web UI makes the server easier to share, which
  makes it easier to expose by mistake. The defaults stay as they are
  (`127.0.0.1`, warning on `0.0.0.0`), and the README is explicit that public
  hosting is out. Commit 1 makes sure no web bundle ever contains the data.
- **No offline play on the web.** Local mode isn't offered in the browser.
  `sqflite_common_ffi_web` could open the database there, but every browser
  would first download 87 MB of the dataset. Out of scope.
- **Token in localStorage** can be read by any script on that origin. Only
  our own code runs there, and it's a light guard for a LAN server anyway.
- **CORS is not supported.** The web UI is only supported when the page and
  the API share an origin. That covers `serve_clues.py --web` and the dev
  proxy. Hosting the page elsewhere would need `Access-Control-*` handling,
  which isn't planned.
- **Decided (later):** the tab title and app name are "Trivia", matching
  the Android launcher label, the iOS display name and the web manifest's
  short name. It was "Random Trivia Question", which no longer fit beside
  the app bar's buttons on a phone. The Android package is
  `com.sawdeydev.quizapp` (it was `com.sawdeydev.jeopardyfun`), and so is the
  iOS bundle ID (it was `com.sawdeydev.jeopardyFun`).
- **Next after this:** round and date filters. `QuestionFilter` is already
  wired through the repository, both dialects and the server, so it is mostly
  a settings sheet, and with the web UI in place it ships to both platforms
  at once. Its plan is [filters-plan.md](filters-plan.md). General trivia
  and multiple choice have their own plan:
  [general-trivia-plan.md](general-trivia-plan.md).
