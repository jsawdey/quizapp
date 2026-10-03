#!/usr/bin/env python3
"""Build the app's SQLite clue database from jwolle1/jeopardy_clue_dataset.

The dataset is property of Jeopardy Productions, Inc. and its author asks that
it not be used for public-facing apps or products. This app is for personal
use only: never commit the downloaded TSV or the generated database.

Usage (from the repository root):
    python3 tool/build_clue_db.py
    python3 tool/build_clue_db.py --input path/to/combined_season1-42.tsv

Only the Python standard library is required.
"""

import argparse
import csv
import datetime
import hashlib
import os
import sqlite3
import sys
import tempfile
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

DATASET_VERSION = 'v42'
DATASET_COMMIT = '5a2026f465cfd9f2b80a478bd1993c9a2223befc'
DATASET_FILE = 'combined_season1-42.tsv'
DATASET_URL = ('https://raw.githubusercontent.com/jwolle1/jeopardy_clue_dataset/'
               f'{DATASET_COMMIT}/{DATASET_FILE}')
DATASET_SHA256 = 'e5e336af75210f9ecfdd68201201d9acea269ea6be8d3dc445e98bf31399c2e2'

DEFAULT_INPUT = REPO_ROOT / 'data' / DATASET_FILE
DEFAULT_OUTPUT = REPO_ROOT / 'assets' / 'db' / 'clues.db'

# Bump when the schema changes so the app knows to replace its installed copy.
SCHEMA_VERSION = 1

EXPECTED_COLUMNS = [
    'round', 'clue_value', 'daily_double_value', 'category', 'comments',
    'answer', 'question', 'air_date', 'notes',
]

SCHEMA = '''
CREATE TABLE meta       (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE games      (id INTEGER PRIMARY KEY, air_date TEXT NOT NULL UNIQUE);
CREATE TABLE categories (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE clues (
  id               INTEGER PRIMARY KEY,
  clue_key         INTEGER NOT NULL,  -- unique; enforced by this script, not an index
  game_id          INTEGER NOT NULL REFERENCES games(id),
  category_id      INTEGER NOT NULL REFERENCES categories(id),
  round            INTEGER NOT NULL,
  value            INTEGER NOT NULL,
  dd_wager         INTEGER NOT NULL,
  category_comment TEXT,
  clue             TEXT NOT NULL,
  response         TEXT NOT NULL,
  notes            TEXT
);
CREATE INDEX clues_round ON clues(round);
'''


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def download(url, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f'Downloading {url}')
    tmp = dest.with_suffix(dest.suffix + '.part')
    with urllib.request.urlopen(url) as response, open(tmp, 'wb') as out:
        while True:
            chunk = response.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
    tmp.replace(dest)


def clean(text):
    """Undo the dataset's backslash escaping (\\" and \\') and drop stray backslashes."""
    text = text.replace('\\"', '"').replace("\\'", "'").replace('\\', '')
    return ' '.join(text.split())


def clue_key(air_date, round_, value, category, clue):
    """A stable identifier for a clue that survives database rebuilds.

    The first 8 bytes of a SHA-1 hash, as a signed 64-bit integer: a 40-character
    hex key and its index would add about 60 MB to the database.
    """
    raw = '|'.join([air_date, str(round_), str(value), category, clue])
    digest = hashlib.sha1(raw.encode('utf-8')).digest()
    return int.from_bytes(digest[:8], 'big', signed=True)


def read_rows(path):
    with open(path, newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f, delimiter='\t', quoting=csv.QUOTE_NONE)
        if reader.fieldnames != EXPECTED_COLUMNS:
            raise ValueError(f'Unexpected columns in {path}: {reader.fieldnames}')
        for line_number, row in enumerate(reader, start=2):
            if None in row or None in row.values():
                raise ValueError(f'{path}:{line_number}: wrong number of columns')
            yield row


def build(input_path, output_path, dataset_version, source_sha256):
    """Build the database at output_path and return a dict of statistics."""
    stats = {'read': 0, 'written': 0, 'dropped_empty': 0, 'dropped_duplicate': 0,
             'rounds': {}}
    games = {}
    categories = {}
    seen_keys = set()
    clues = []

    for row in read_rows(input_path):
        stats['read'] += 1
        category = clean(row['category'])
        # The dataset uses Jeopardy's naming: `answer` is the clue shown to
        # contestants and `question` is the correct response.
        clue = clean(row['answer'])
        response = clean(row['question'])
        if not category or not clue or not response:
            stats['dropped_empty'] += 1
            continue

        air_date = row['air_date'].strip()
        datetime.date.fromisoformat(air_date)  # Fail loudly on a malformed date.
        round_ = int(row['round'])
        value = int(row['clue_value'])
        key = clue_key(air_date, round_, value, category, clue)
        if key in seen_keys:
            stats['dropped_duplicate'] += 1
            continue
        seen_keys.add(key)

        game_id = games.setdefault(air_date, len(games) + 1)
        category_id = categories.setdefault(category, len(categories) + 1)
        clues.append((
            len(clues) + 1, key, game_id, category_id, round_, value,
            int(row['daily_double_value']), clean(row['comments']) or None,
            clue, response, clean(row['notes']) or None,
        ))
        stats['rounds'][round_] = stats['rounds'].get(round_, 0) + 1

    stats['written'] = len(clues)
    stats['games'] = len(games)
    stats['categories'] = len(categories)

    # Build into a temporary file so a failed run never leaves a partial database.
    output_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(suffix='.db', dir=output_path.parent)
    os.close(fd)
    tmp_path = Path(tmp_name)
    try:
        conn = sqlite3.connect(tmp_path)
        with conn:
            conn.executescript(SCHEMA)
            conn.executemany('INSERT INTO games (id, air_date) VALUES (?, ?)',
                             ((i, d) for d, i in games.items()))
            conn.executemany('INSERT INTO categories (id, name) VALUES (?, ?)',
                             ((i, n) for n, i in categories.items()))
            conn.executemany('INSERT INTO clues VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                             clues)
            conn.executemany('INSERT INTO meta (key, value) VALUES (?, ?)', [
                ('schema_version', str(SCHEMA_VERSION)),
                ('dataset_version', dataset_version),
                ('source_sha256', source_sha256),
                ('built_at', datetime.datetime.now(datetime.timezone.utc)
                    .replace(microsecond=0).isoformat()),
                ('clue_count', str(len(clues))),
            ])
        conn.execute('VACUUM')
        conn.close()
        tmp_path.replace(output_path)
    finally:
        if tmp_path.exists():
            tmp_path.unlink()

    stats['size_bytes'] = output_path.stat().st_size
    return stats


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--input', type=Path, default=DEFAULT_INPUT,
                        help='TSV file to import; downloaded from --url if missing '
                             '(default: %(default)s)')
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT,
                        help='database to write (default: %(default)s)')
    parser.add_argument('--url', default=DATASET_URL,
                        help='where to download the TSV from (default: %(default)s)')
    parser.add_argument('--sha256', default=DATASET_SHA256,
                        help='expected SHA-256 of the TSV; pass an empty string to skip '
                             'the check (default: %(default)s)')
    parser.add_argument('--dataset-version', default=DATASET_VERSION,
                        help='dataset release recorded in the meta table '
                             '(default: %(default)s)')
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)

    if not args.input.exists():
        download(args.url, args.input)

    actual_sha256 = sha256_of(args.input)
    if args.sha256 and actual_sha256 != args.sha256:
        print(f'error: {args.input} has SHA-256 {actual_sha256}, expected {args.sha256}.\n'
              'Delete it to download again, or pass --sha256 for a different release.',
              file=sys.stderr)
        return 1

    stats = build(args.input, args.output, args.dataset_version, actual_sha256)

    rounds = ', '.join(f'round {r}: {n}' for r, n in sorted(stats['rounds'].items()))
    print(f'Wrote {args.output} ({stats["size_bytes"] / 1e6:.1f} MB)\n'
          f'  clues:      {stats["written"]} of {stats["read"]} read ({rounds})\n'
          f'  dropped:    {stats["dropped_empty"]} empty, '
          f'{stats["dropped_duplicate"]} duplicate\n'
          f'  games:      {stats["games"]}\n'
          f'  categories: {stats["categories"]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
