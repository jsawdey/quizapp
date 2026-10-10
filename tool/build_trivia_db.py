#!/usr/bin/env python3
"""Build the app's offline trivia database from Open Trivia Database.

Downloads every question OpenTDB serves (about 5,300) with a session token, at
one request every 6 seconds as its API asks, which takes about 12 minutes.
The download is kept in data/ so rebuilding is instant; pass --refresh to
download again. Then writes assets/db/trivia.db, which the app reads with
LOCAL_DATASET=trivia and serve_clues.py can serve.

The questions are licensed CC BY-SA 4.0 by Open Trivia Database (opentdb.com):
unlike the clue database they may be shared, with that credit and under that
license. The database is still git-ignored, as a build output.

Usage (from the repository root):
    python3 tool/build_trivia_db.py
    python3 tool/build_trivia_db.py --refresh

Only the Python standard library is required.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import sqlite3
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_INPUT = REPO_ROOT / 'data' / 'opentdb_questions.json'
DEFAULT_OUTPUT = REPO_ROOT / 'assets' / 'db' / 'trivia.db'
DEFAULT_BASE = 'https://opentdb.com'

# Bump when the schema changes so the app knows to replace its installed copy.
SCHEMA_VERSION = 1
NAMESPACE = 'opentdb'
LICENSE = 'CC BY-SA 4.0'
# As OpenTdbDialect.attribution in the app.
ATTRIBUTION = 'Questions from Open Trivia Database (opentdb.com), CC BY-SA 4.0'

BATCH_SIZE = 50
REQUEST_GAP = 6.0
RATE_LIMIT_PAUSE = 10.0
MAX_RATE_LIMITED = 5

SCHEMA = '''
CREATE TABLE meta      (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE questions (
  id         INTEGER PRIMARY KEY,  -- 1..N with no gaps
  key        TEXT NOT NULL UNIQUE, -- as OpenTdbDialect.questionKey in the app
  category   TEXT NOT NULL,
  difficulty TEXT,
  question   TEXT NOT NULL,
  answer     TEXT NOT NULL,
  choices    TEXT NOT NULL         -- JSON array, in the order to show them
);
'''

# A % not followed by two hex digits: the app's decoder rejects these.
BAD_PERCENT = re.compile(r'%(?![0-9A-Fa-f]{2})')


class FetchError(Exception):
    pass


def decode(value):
    """Decodes a url3986 field and trims it, as the app does; None if invalid."""
    if not isinstance(value, str) or BAD_PERCENT.search(value):
        return None
    try:
        text = urllib.parse.unquote(value, errors='strict').strip()
    except UnicodeDecodeError:
        return None
    return text or None


def sha256_hex(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def question_key(category, question, answer):
    """As OpenTdbDialect.questionKey: hides carry across the API and this copy."""
    return sha256_hex(f'{category}\0{question}\0{answer}')[:16]


def stable_shuffle(key, choices):
    """As OpenTdbDialect.stableShuffle: ranked by the hash of key and choice."""
    return sorted(choices, key=lambda choice: sha256_hex(f'{key}\0{choice}'))


def parse_item(item):
    """A row dict for one API item, or None if the app would skip it."""
    if not isinstance(item, dict):
        return None
    question = decode(item.get('question'))
    answer = decode(item.get('correct_answer'))
    category = decode(item.get('category'))
    incorrect = item.get('incorrect_answers')
    if question is None or answer is None or category is None or not isinstance(incorrect, list):
        return None
    others = [decode(choice) for choice in incorrect]
    if None in others:
        return None
    key = question_key(category, question, answer)
    if item.get('type') == 'boolean':
        choices = ['True', 'False']
    elif item.get('type') == 'multiple':
        choices = stable_shuffle(key, [answer, *others])
    else:
        return None
    if len(choices) < 2 or len(set(choices)) != len(choices) or answer not in choices:
        return None
    difficulty = item.get('difficulty')
    return {
        'key': key,
        'category': category,
        'difficulty': difficulty.lower() if isinstance(difficulty, str) and difficulty else None,
        'question': question,
        'answer': answer,
        'choices': choices,
    }


def http_get_json(url):
    """Returns (HTTP status, decoded JSON)."""
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            return response.status, json.loads(response.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode('utf-8'))
        except ValueError:
            return e.code, None


def fetch_all(base, get_json=http_get_json, sleep=time.sleep, gap=REQUEST_GAP, log=print):
    """Every question OpenTDB serves, as the raw (still encoded) items.

    A token keeps the API from repeating itself. It answers code 4 once a
    batch is bigger than what's left, so the batch halves down to 1 before
    the download counts as complete.
    """
    base = base.rstrip('/')
    status, body = get_json(f'{base}/api_token.php?command=request')
    if status != 200 or not isinstance(body, dict) or body.get('response_code') != 0:
        raise FetchError(f'could not get a session token (HTTP {status}): {body}')
    token = body['token']
    results, amount, rate_limited = [], BATCH_SIZE, 0
    while True:
        sleep(gap)
        query = urllib.parse.urlencode({'amount': amount, 'encode': 'url3986', 'token': token})
        status, body = get_json(f'{base}/api.php?{query}')
        code = body.get('response_code') if isinstance(body, dict) else None
        if code == 5 or status == 429:
            rate_limited += 1
            if rate_limited > MAX_RATE_LIMITED:
                raise FetchError('rate limited too many times in a row')
            sleep(RATE_LIMIT_PAUSE)
            continue
        rate_limited = 0
        if code == 0:
            before = len(results)
            results.extend(body.get('results', []))
            if before // 500 != len(results) // 500:
                log(f'  {len(results)} questions…')
        elif code in (1, 4):
            if amount == 1:
                return results
            amount //= 2
        else:
            raise FetchError(f'unexpected response (HTTP {status}): {body}')


def version_path(db_path):
    """The JSON file written next to the database (trivia.db -> trivia.version)."""
    return db_path.with_suffix('.version')


def build(items, output_path, fetched_at, source):
    """Writes the database at output_path from raw API items; returns statistics."""
    stats = {'read': len(items), 'written': 0, 'skipped': 0, 'duplicate': 0}
    rows, seen = [], set()
    for item in items:
        row = parse_item(item)
        if row is None:
            stats['skipped'] += 1
            continue
        if row['key'] in seen:
            stats['duplicate'] += 1
            continue
        seen.add(row['key'])
        rows.append(row)
    rows.sort(key=lambda r: (r['category'], r['key']))
    stats['written'] = len(rows)
    stats['categories'] = len({r['category'] for r in rows})

    meta = {
        'schema_version': str(SCHEMA_VERSION),
        'dataset_namespace': NAMESPACE,
        'dataset_kind': 'trivia',
        'license': LICENSE,
        'attribution': ATTRIBUTION,
        'source': source,
        'fetched_at': fetched_at,
        'built_at': datetime.datetime.now(datetime.timezone.utc)
            .replace(microsecond=0).isoformat(),
        'question_count': str(len(rows)),
    }

    # Build into a temporary file so a failed run never leaves a partial database.
    output_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(suffix='.db', dir=output_path.parent)
    os.close(fd)
    tmp_path = Path(tmp_name)
    try:
        conn = sqlite3.connect(tmp_path)
        try:
            write(conn, rows, meta)
            conn.execute('VACUUM')
        finally:
            conn.close()
        tmp_path.replace(output_path)
    finally:
        if tmp_path.exists():
            tmp_path.unlink()

    version_tmp = version_path(output_path).with_suffix('.version.part')
    version_tmp.write_text(json.dumps(meta, sort_keys=True) + '\n', encoding='utf-8')
    version_tmp.replace(version_path(output_path))
    stats['size_bytes'] = output_path.stat().st_size
    return stats


def write(conn, rows, meta):
    """Creates the tables and fills them in one transaction."""
    with conn:
        conn.executescript(SCHEMA)
        conn.executemany(
            'INSERT INTO questions (id, key, category, difficulty, question, answer, choices) '
            'VALUES (?, ?, ?, ?, ?, ?, ?)',
            ((i, r['key'], r['category'], r['difficulty'], r['question'], r['answer'],
              json.dumps(r['choices'], ensure_ascii=False))
             for i, r in enumerate(rows, start=1)))
        conn.executemany('INSERT INTO meta (key, value) VALUES (?, ?)', meta.items())


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--input', type=Path, default=DEFAULT_INPUT,
                        help='downloaded questions; fetched from --base if missing '
                             '(default: %(default)s)')
    parser.add_argument('--refresh', action='store_true',
                        help='download the questions again even if --input exists')
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT,
                        help='database to write (default: %(default)s)')
    parser.add_argument('--base', default=DEFAULT_BASE,
                        help='Open Trivia Database URL (default: %(default)s)')
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if args.refresh or not args.input.exists():
        print(f'Downloading every question from {args.base}; this takes about 12 minutes.')
        try:
            items = fetch_all(args.base)
        except (FetchError, OSError) as e:
            print(f'error: {e}', file=sys.stderr)
            return 1
        fetched_at = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
        args.input.parent.mkdir(parents=True, exist_ok=True)
        tmp = args.input.with_suffix('.part')
        tmp.write_text(json.dumps({'source': args.base, 'fetched_at': fetched_at,
                                   'results': items}, ensure_ascii=False), encoding='utf-8')
        tmp.replace(args.input)
    saved = json.loads(args.input.read_text(encoding='utf-8'))
    stats = build(saved['results'], args.output, saved['fetched_at'], saved['source'])
    print(f'Wrote {args.output} ({stats["size_bytes"] / 1e6:.1f} MB)\n'
          f'  questions:  {stats["written"]} of {stats["read"]} read '
          f'({stats["skipped"]} skipped, {stats["duplicate"]} duplicate)\n'
          f'  categories: {stats["categories"]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
