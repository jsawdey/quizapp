# quizapp

A fun quiz app written in Flutter that utilizes jService (jservice.io) to retrieve questions/answers.

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
