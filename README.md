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
