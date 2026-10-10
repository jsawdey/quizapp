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

**In the app**, the ⇄ button in the app bar ("Questions from") switches
between the sources the build can use, and the app remembers the choice:

- the source the build was configured with (below), always listed first;
- **Jeopardy! clues** and **Trivia** on the device, if `clues.db` or
  `trivia.db` was bundled (phone and desktop builds only);
- **Open Trivia Database** and **The Trivia API**, online.

Hidden questions and the filter carry over; each source applies the parts
of the filter it supports. Only the configured server gets the access token.

**At build time**, the settings below pick that configured source, which is
also the default. Questions come from the local clue database unless you say
otherwise, so after building it `flutter run` just works. To read from an
HTTP API instead, copy
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
  - `opentdb`: [Open Trivia Database](https://opentdb.com), with
    `QUESTION_API_URL` set to `https://opentdb.com`. See
    [General trivia](#general-trivia-open-trivia-database).
  - `thetriviaapi`: [The Trivia API](https://the-trivia-api.com), with
    `QUESTION_API_URL` set to `https://the-trivia-api.com`. See
    [The Trivia API](#the-trivia-api).
- `QUESTION_API_TOKEN`: optional bearer token. It is compiled into the app.
- `LOCAL_DATASET`: which bundled database `local` and `api_with_local_fallback`
  read: `clues` (default) or `trivia` (see
  [Offline trivia](#offline-trivia)).

An app built without the clue database (for API use) leaves out its ~43 MB;
if it is set to `local` it says the database is missing. With
`api_with_local_fallback` it only needs the database while the API is down.
Questions you hide stay hidden across the local database and a `quizapp` API
serving the same dataset.

## General trivia (Open Trivia Database)

Set `QUESTION_SOURCE` to `api`, `QUESTION_API_URL` to `https://opentdb.com`
and `QUESTION_API_DIALECT` to `opentdb` to play general trivia instead of
Jeopardy clues: multiple choice and true or false, easy to hard, in
categories from General Knowledge to Video Games. Its questions are licensed
CC BY-SA 4.0, so unlike the clue database they aren't for personal use only;
the app credits them under the copyright button in the app bar. It works in
web builds too, since Open Trivia Database allows requests from any page.

The app asks for a session token when it starts, so questions don't repeat
until all of them (about 5,300) have been seen, then starts a new one. It
fetches 50 at a time, at most one batch every 5 seconds, as the API asks.
Questions you hide stay hidden on that device. The filters offer its
categories and three difficulties.

### Offline trivia

Open Trivia Database's license allows keeping a copy, so the app can also
play its questions with no network at all:

```
python3 tool/build_trivia_db.py
```

downloads every question (about 12 minutes, at the pace the API asks for;
the download is kept in `data/` so rebuilding is instant, and `--refresh`
downloads again) and writes `assets/db/trivia.db`, a few MB. Build the app
with `QUESTION_SOURCE=local` and `LOCAL_DATASET=trivia` to play it, or with
`api_with_local_fallback`, `QUESTION_API_DIALECT=opentdb` and
`LOCAL_DATASET=trivia` to use the live API and fall back to the copy. Keys
match the live API's, so a hidden question stays hidden across both.

Everything in `assets/db/` is bundled into phone builds, so a build for
trivia also carries `clues.db` (~87 MB) if you've built it; move it out of
`assets/db/` first to leave it out. Web builds bundle neither.

`serve_clues.py` serves the copy too, to phones and browsers on your network
(see [Serving questions](#serving-questions-from-your-own-computer)).

`tool/capture_opentdb.py` saves fresh responses from the live API into
`test/support/opentdb/`, which the dialect's tests read; rerun it and the
tests if the API seems to have changed.

### The Trivia API

Set `QUESTION_API_URL` to `https://the-trivia-api.com` and
`QUESTION_API_DIALECT` to `thetriviaapi` for a second source of general
trivia: thousands of multiple-choice questions in 10 categories, filtered by
category and difficulty like OpenTDB's, in web builds too. Its license is
CC BY-NC 4.0, so **non-commercial use only**; fine for this personal app, and
credited under the copyright button. It has no session, so questions can
come round again sooner than with OpenTDB, and there is no offline copy.
`tool/capture_trivia_api.py` saves fresh responses for its tests, as
`capture_opentdb.py` does for OpenTDB's.

### Multiple-choice questions

A question can come with answer choices. Then a button for each choice sits
under the question (numbered, and picked with keys 1–4, on a keyboard).
Picking one marks the right answer green and a wrong pick red. Tapping the
card still shows the answer, for playing it as a flash card. The line under
the category shows the question's difficulty when it has no dollar value.

Open Trivia Database serves them, and so can a `quizapp` API, by adding
optional `choices` (every option in the order to show them, the response
among them) and `difficulty` to a question. A source whose license asks for
credit shows it in the raw data overlay and under the copyright button in the
app bar. The design is in
[docs/general-trivia-plan.md](docs/general-trivia-plan.md).

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

Filters work with the local databases, the `quizapp` API, Open Trivia
Database and The Trivia API; for general trivia they pick categories and a difficulty (easy,
medium or hard) instead. A jService API can't filter, so the button isn't
shown for it, and with
`api_with_local_fallback` the app only offers filters both sources support.
The design is in [docs/filters-plan.md](docs/filters-plan.md).

## Serving questions from your own computer

`tool/serve_clues.py` serves the clue database, or the trivia database with
`--db assets/db/trivia.db`, over the `quizapp` API, using only the Python
standard library. The app asks the server which it holds and offers the
matching filters. One server can feed several devices, a phone
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

**Personal use only** for the clue database: the dataset's terms rule out
public-facing use, so keep the server on your own network, never the
internet. The trivia database is CC BY-SA 4.0, so the server doesn't warn
about it, though that's no reason to expose it. The token is a light guard,
not real security.

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
