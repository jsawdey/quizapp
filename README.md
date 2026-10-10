# quizapp

A fun Jeopardy-style quiz app written in Flutter. It shows a random clue; tap
it to see the response. It runs on phones and, served from your own computer,
in a browser (see [Playing in a browser](#playing-in-a-browser)).

Questions come from a local database of real Jeopardy! clues built from the
[jwolle1/jeopardy_clue_dataset](https://github.com/jwolle1/jeopardy_clue_dataset),
or from an HTTP API you point it at (see below). The app used to read from
jService (jservice.io), which has shut down. The design is in
[docs/question-backend-plan.md](docs/question-backend-plan.md).

Because of the dataset's terms, this app is for personal use only.

## Getting Started

For help getting started with Flutter, view our online
[documentation](https://flutter.io/).

## Building the clue database

Questions come from a local SQLite database built from the
[jwolle1/jeopardy_clue_dataset](https://github.com/jwolle1/jeopardy_clue_dataset)
(release v42). The data is property of Jeopardy Productions, Inc. and the dataset
author asks that it not be used for public-facing apps, so this app is for
personal use only. The dataset and the generated database are git-ignored;
never commit them.

Build it with Python 3 (standard library only) from the repository root:

```
python3 tool/build_clue_db.py
```

This downloads the dataset to `data/`, checks its SHA-256, drops the few clues
that need a picture, video or audio clip, and writes `assets/db/clues.db`
(about 87 MB). Run `python3 tool/build_clue_db.py --help`
for options, such as importing a newer dataset release. The script's tests run
with `python3 -m unittest discover tool`.

## Choosing the question source

Questions come from the local clue database by default, so after building it
`flutter run` just works. To read from an HTTP API instead, copy
`config/question_source.example.json` to `config/question_source.json`
(git-ignored), fill it in and pass it to Flutter:

```
flutter run --dart-define-from-file=config/question_source.json
```

- `QUESTION_SOURCE`: `local` (default), `api`, or `api_with_local_fallback`
  (the API, switching to the local database while the API is unreachable and
  trying the API again after a minute).
- `QUESTION_API_URL`: the API's base URL. Release builds require `https`;
  debug and profile builds also allow `http`, for a server on your local network.
- `QUESTION_API_DIALECT`: which API it is:
  - `quizapp`: this app's own API, described in
    [docs/question-backend-plan.md](docs/question-backend-plan.md) (§7).
  - `jservice`: the original jService routes, as served by self-hosted copies
    and clones.
- `QUESTION_API_TOKEN`: optional bearer token. It is compiled into the app.

An app built without the clue database (for API use) leaves out its ~43 MB;
if it is set to `local` it says the database is missing. With
`api_with_local_fallback` it only needs the database while the API is down.
Questions you hide stay hidden across the local database and a `quizapp` API
serving the same dataset.

## Multiple-choice questions

A question can come with answer choices. Then a button for each choice sits
under the question (numbered, and picked with keys 1–4, on a keyboard).
Picking one marks the right answer green and a wrong pick red. Tapping the
card still shows the answer, for playing it as a flash card. The line under
the category shows the question's difficulty when it has no dollar value.

A `quizapp` API serves them by adding optional `choices` (every option in the
order to show them, the response among them) and `difficulty` to a question.
No source serves them yet; Open Trivia Database support is planned in
[docs/general-trivia-plan.md](docs/general-trivia-plan.md). A source whose
license asks for credit shows it in the raw data overlay and under the
copyright button in the app bar.

## Filtering clues

The filter button in the app bar (or F on a keyboard) picks which rounds to
play (Jeopardy!, Double Jeopardy! and Final Jeopardy!), a range of years the
clues aired, and a difficulty: the clue's row on the board, from 1 (top) to 5
(bottom). Rows mean the same thing before and after clue values doubled in
2001, Daily Doubles count in their row, and Final Jeopardy has no row, so that
filter leaves it alone. Apply loads a matching clue straight away, and the
filter is kept between launches. While a filter is on, the button is filled in
and its tooltip says which filter it is. If no clue matches, the board offers
to change or clear the filters.

Filters work with the local database and the `quizapp` API. A jService API
can't filter, so the button isn't shown for it, and with
`api_with_local_fallback` the app only offers filters both sources support.
The design is in [docs/filters-plan.md](docs/filters-plan.md).

## Serving questions from your own computer

`tool/serve_clues.py` serves the clue database over the `quizapp` API, using
only the Python standard library. One server can feed several devices, a phone
build can leave out the database, and a question hidden on one device is
hidden on all of them.

```
python3 tool/build_clue_db.py
python3 tool/serve_clues.py --host 0.0.0.0 --token SOME-SECRET
```

By default it listens on `127.0.0.1:8080`; `--host 0.0.0.0` makes it
reachable from your local network. Reported questions are kept in
`data/reports.db`. Run it with `--help` for the other options. Its tests run
with the other tool tests; `test/serve_clues_contract_test.dart` checks the
app against it.

**Personal use only.** The dataset's terms rule out public-facing use, so keep
the server on your own network, never the internet. The token is a light
guard, not real security.

Point a **debug or profile** build at it over plain `http`:

```json
{
  "QUESTION_SOURCE": "api_with_local_fallback",
  "QUESTION_API_URL": "http://192.168.1.20:8080",
  "QUESTION_API_DIALECT": "quizapp",
  "QUESTION_API_TOKEN": "SOME-SECRET"
}
```

```
flutter run --profile --dart-define-from-file=config/question_source.json
```

### Release builds need HTTPS

Release builds refuse plain `http`, so put a server with a real (publicly
trusted) certificate in front of `serve_clues.py`. Self-signed certificates
and private certificate authorities won't work: Android apps don't trust
user-installed certificates by default. Two ways that keep the server off the
public internet:

- **Tailscale.** On the computer running `serve_clues.py` (left on
  `127.0.0.1`), run `tailscale serve --bg 8080`. That serves it at
  `https://<computer>.<tailnet>.ts.net` with a valid certificate, reachable
  only from your own Tailscale devices. Use that address as
  `QUESTION_API_URL`. See Tailscale's
  [serve docs](https://tailscale.com/kb/1312/serve).
- **Caddy with your own domain.** Give the server a name in a domain you own
  that resolves to its LAN address, and run [Caddy](https://caddyserver.com/)
  as a reverse proxy to `localhost:8080`. Because the name points at a private
  address, Caddy needs the DNS challenge (a build with your DNS provider's
  plugin) to get its certificate; see Caddy's
  [automatic HTTPS docs](https://caddyserver.com/docs/automatic-https#dns-challenge).

## Playing in a browser

`serve_clues.py` can also serve the app itself, so any device on your network
can play by opening the server's address, with nothing to install. The
design is in [docs/web-ui-plan.md](docs/web-ui-plan.md).

```
python3 tool/build_clue_db.py
flutter build web --no-web-resources-cdn
python3 tool/serve_clues.py --host 0.0.0.0 --web build/web --token SOME-SECRET
```

Then open `http://<this computer>:8080/`.

- **Build with `--no-web-resources-cdn`.** Without it, the page loads its
  renderer and fonts from Google's servers and stays blank on a device
  without internet access. `serve_clues.py` warns about such builds.
- **No settings needed.** A web build reads from the server that served the
  page, using the `quizapp` API. It can't use the local clue database (that
  isn't bundled into web builds, which anyone loading the page could
  download), so `local` and `api_with_local_fallback` are refused.
- **The token is entered in the page.** If the server has `--token`, the page
  asks for it once and keeps it in the browser's storage. Don't put
  `QUESTION_API_TOKEN` in a web build: anyone who loads the page could read
  it, so the build refuses it. The app's files themselves don't need the
  token; they contain no clues.
- **Keyboard:** Space or Enter flips the card, N or → loads the next clue, H
  hides the clue, F opens the filters, and 1–4 pick a choice.
- Hidden clues are kept in the browser's storage, and reported to the server
  so every device stops seeing them.
- **Personal use only**, as above: keep the server on your own network. Don't
  publish `build/web` on a public host either; it needs the server anyway.
  `tailscale serve` (see above) also gives the web UI https.

To work on the web UI, start the server and run the app in Chrome. Requests
to `/v1/` are forwarded to the server (see `web_dev_config.yaml`), so it reads
real clues with hot reload:

```
python3 tool/serve_clues.py
flutter run -d chrome
```
