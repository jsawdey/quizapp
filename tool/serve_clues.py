#!/usr/bin/env python3
"""Serve the clue or trivia database over HTTP, using the app's `quizapp` API (v1).

The clue dataset is property of Jeopardy Productions, Inc. and its author asks
that it not be used for public-facing apps or products. Served from the clue
database, this server is for your own devices only: keep it on localhost or
your home network, never the internet. The trivia database (from
tool/build_trivia_db.py) is CC BY-SA 4.0 Open Trivia Database questions, which
may be shared with credit; the app shows it.

Usage (from the repository root, after python3 tool/build_clue_db.py):
    python3 tool/serve_clues.py                              # localhost only
    python3 tool/serve_clues.py --host 0.0.0.0 --token SECRET  # your LAN
    python3 tool/serve_clues.py --web build/web              # plus the web UI
    python3 tool/serve_clues.py --db assets/db/trivia.db     # general trivia

Then build the app with QUESTION_SOURCE=api (or api_with_local_fallback),
QUESTION_API_DIALECT=quizapp and QUESTION_API_URL=http://<this computer>:8080.
Release builds need https; see README.md. With --web, after
flutter build web --no-web-resources-cdn, browsers can play at
http://<this computer>:8080/.

API (docs/question-backend-plan.md section 7):
    GET  /v1/info      what is served: kind, filters, categories, credit
    GET  /v1/random?count=10[&round=1,2][&from=YYYY-MM-DD][&to=YYYY-MM-DD][&row=4,5]
    GET  /v1/random?count=10[&category=Art&category=History][&difficulty=easy,hard]
         (trivia; an empty "questions" list when nothing matches the filters)
    POST /v1/questions/{key}/report
    POST /v1/history   answers and games from the player's devices
    GET  /v1/history?after=SEQ[&limit=1000]   what changed after SEQ
         (score history; docs/history-plan.md section 4)

With --token, the API needs the bearer token but the web UI's files don't:
they hold no clues, and the page asks for the token.

The environment variables QUIZ_DB and QUIZ_TOKEN, if set, stand in for --db
and --token (the Docker image uses them; see docs/docker-plan.md).

Reported questions are kept in a separate database (--reports) and never
served again, so hiding one on one device hides it on all of them. The score
history is kept in another (--history), and handed back to every device.

Only the Python standard library is required.
"""

import argparse
import contextlib
import datetime
import email.utils
import hmac
import json
import mimetypes
import os
import random
import re
import secrets
import signal
import sqlite3
import sys
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DB = REPO_ROOT / 'assets' / 'db' / 'clues.db'
# Not next to clues.db: everything in assets/db/ is bundled into the app.
DEFAULT_REPORTS = REPO_ROOT / 'data' / 'reports.db'
DEFAULT_HISTORY = REPO_ROOT / 'data' / 'history.db'

SUPPORTED_SCHEMA_VERSION = 1
MAX_COUNT = 50
DEFAULT_COUNT = 10
# Random picks to try per requested clue before returning fewer than asked.
ATTEMPTS_PER_CLUE = 5

# The day clue values doubled. A clue's board row (1 top to 5 bottom) is its
# value over its round's top-row value, which doubled then; as
# Question.boardRow in the app.
VALUES_DOUBLED_ON = '2001-11-26'
ROW_BASE = ('(CASE c.round WHEN 1 THEN 100 ELSE 200 END '
            '* CASE WHEN g.air_date >= ? THEN 2 ELSE 1 END)')

SELECT = '''
    SELECT c.id, c.clue_key, c.round, c.value, c.dd_wager, c.category_comment,
           c.clue, c.response, c.notes, cat.name AS category, g.air_date
    FROM clues c
    JOIN categories cat ON cat.id = c.category_id
    JOIN games g ON g.id = c.game_id'''


# Types mimetypes may not know, or gets wrong on some systems. WebAssembly has
# to be application/wasm for browsers to compile it while it downloads.
WEB_CONTENT_TYPES = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.mjs': 'text/javascript; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.wasm': 'application/wasm',
    '.otf': 'font/otf',
    '.ttf': 'font/ttf',
    '.png': 'image/png',
}


class StorageUnavailable(Exception):
    """A database of the server's own (reports, history) can't be created or opened."""


def load_reported(reports_path, create_table, select_keys):
    """Creates the reported-question table if needed; returns the reported keys."""
    try:
        reports_path.parent.mkdir(parents=True, exist_ok=True)
        with contextlib.closing(sqlite3.connect(reports_path)) as conn:
            conn.execute(create_table)
            return {row[0] for row in conn.execute(select_keys)}
    except (OSError, sqlite3.Error) as e:
        # Often a Docker volume owned by another user (docs/docker-plan.md).
        raise StorageUnavailable(
            f'cannot keep reported questions in {reports_path.resolve()}: {e}') from e


class BadRequest(Exception):
    pass


class TooLarge(Exception):
    pass


def read_meta(db_path):
    """The meta table of the database at db_path, opened read-only."""
    uri = Path(db_path).resolve().as_uri() + '?mode=ro'
    with contextlib.closing(sqlite3.connect(uri, uri=True)) as conn:
        return dict(conn.execute('SELECT key, value FROM meta'))


def open_store(db_path, reports_path, rng=None):
    """A ClueStore or TriviaStore, as the database's dataset_kind says."""
    if read_meta(db_path).get('dataset_kind') == 'trivia':
        return TriviaStore(db_path, reports_path, rng)
    return ClueStore(db_path, reports_path, rng)


class ClueStore:
    """Read-only access to the clue database plus the reported-clue list."""

    kind = 'clues'
    filters = ['round', 'air_date', 'row']
    # The dataset's terms: personal use only.
    license = None

    def __init__(self, db_path, reports_path, rng=None):
        self.db_uri = Path(db_path).resolve().as_uri() + '?mode=ro'
        self.reports_path = Path(reports_path)
        self.rng = rng or random.Random()
        self._lock = threading.Lock()
        self._id_ranges = {}

        with self._clues() as conn:
            meta = dict(conn.execute('SELECT key, value FROM meta'))
            schema = meta.get('schema_version')
            if schema != str(SUPPORTED_SCHEMA_VERSION):
                raise ValueError(f'{db_path} has schema version {schema}; this server '
                                 f'reads version {SUPPORTED_SCHEMA_VERSION}. Rebuild it.')
            self.namespace = meta.get('dataset_namespace', 'jwolle1')
            self.max_id = conn.execute('SELECT MAX(id) FROM clues').fetchone()[0] or 0

        self.reported = load_reported(self.reports_path, '''
            CREATE TABLE IF NOT EXISTS reported (
              clue_key    INTEGER PRIMARY KEY,
              reported_at TEXT NOT NULL)''', 'SELECT clue_key FROM reported')

    def _clues(self):
        # One connection per call: the server handles requests on many threads.
        return contextlib.closing(sqlite3.connect(self.db_uri, uri=True))

    def _reports(self):
        return contextlib.closing(sqlite3.connect(self.reports_path))

    def _id_range(self, conn, date_from, date_to):
        """The first and last clue ids aired from date_from to date_to, or None.

        build_clue_db.py numbers clues in air-date order, so a date range is a
        range of ids, found by binary search and cached. The query still checks
        the dates, so the order only affects fairness.
        """
        if date_from is None and date_to is None:
            return 1, self.max_id
        key = (date_from, date_to)
        with self._lock:
            if key in self._id_ranges:
                return self._id_ranges[key]

        def first_id(test):
            low, high = 1, self.max_id + 1
            while low < high:
                mid = (low + high) // 2
                air_date = conn.execute('SELECT g.air_date FROM clues c JOIN games g '
                                        'ON g.id = c.game_id WHERE c.id = ?', (mid,)).fetchone()[0]
                if test(air_date):
                    high = mid
                else:
                    low = mid + 1
            return low

        first = 1 if date_from is None else first_id(lambda d: d >= date_from)
        last = self.max_id if date_to is None else first_id(lambda d: d > date_to) - 1
        bounds = (first, last) if first <= last else None
        with self._lock:
            self._id_ranges[key] = bounds
        return bounds

    def random(self, count, rounds=None, date_from=None, date_to=None, rows=None):
        if self.max_id == 0:
            return []
        where, args = ['c.id >= ?', 'c.id <= ?'], []
        if rounds is not None:
            # The unary plus keeps SQLite off the round index, which would sort
            # every matching clue; walking forward by id finds one in a few rows.
            where.append(f'+c.round IN ({", ".join("?" * len(rounds))})')
            args.extend(sorted(rounds))
        if date_from is not None:
            where.append('g.air_date >= ?')
            args.append(date_from)
        if date_to is not None:
            where.append('g.air_date <= ?')
            args.append(date_to)
        if rows is not None:
            # Final Jeopardy has no row, and passes whenever its round does.
            where.append(f'(c.round = 3 OR (c.value % {ROW_BASE} = 0 '
                         f'AND c.value / {ROW_BASE} IN ({", ".join("?" * len(rows))})))')
            args.extend([VALUES_DOUBLED_ON, VALUES_DOUBLED_ON, *sorted(rows)])
        sql = f'{SELECT} WHERE {" AND ".join(where)} ORDER BY c.id LIMIT 1'

        found = {}
        with self._clues() as conn:
            bounds = self._id_range(conn, date_from, date_to)
            if bounds is None:
                return []
            first, last = bounds
            conn.row_factory = sqlite3.Row
            for _ in range(count * ATTEMPTS_PER_CLUE):
                if len(found) == count:
                    break
                start = self.rng.randint(first, last)
                row = conn.execute(sql, [start, last, *args]).fetchone()
                if row is None and start > first:
                    row = conn.execute(sql, [first, last, *args]).fetchone()
                if row is None:
                    break  # Nothing matches the filter at all.
                if row['clue_key'] not in self.reported:
                    found.setdefault(row['clue_key'], row)
        return [_to_json(row) for row in found.values()]

    def random_from_query(self, query):
        count, rounds, date_from, date_to, rows = parse_random_query(query)
        return self.random(count, rounds, date_from, date_to, rows)

    def parse_key(self, text):
        try:
            return int(text)
        except ValueError:
            raise BadRequest('question keys are integers')

    def info(self):
        return {'namespace': self.namespace, 'kind': self.kind, 'filters': self.filters,
                'count': self.max_id}

    def report(self, key):
        """Records a report; returns False if no clue has that key."""
        with self._clues() as conn:
            if conn.execute('SELECT 1 FROM clues WHERE clue_key = ?', (key,)).fetchone() is None:
                return False
        now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
        with self._lock, self._reports() as conn:
            conn.execute('INSERT OR IGNORE INTO reported (clue_key, reported_at) VALUES (?, ?)',
                         (key, now))
            conn.commit()
            self.reported.add(key)
        return True


class TriviaStore:
    """Read-only access to the trivia database plus its reported-question list."""

    kind = 'trivia'
    filters = ['category', 'difficulty']
    difficulties = ('easy', 'medium', 'hard')

    def __init__(self, db_path, reports_path, rng=None):
        self.db_uri = Path(db_path).resolve().as_uri() + '?mode=ro'
        self.reports_path = Path(reports_path)
        self.rng = rng or random.Random()
        self._lock = threading.Lock()
        self._counts = {}

        meta = read_meta(db_path)
        schema = meta.get('schema_version')
        if schema != str(SUPPORTED_SCHEMA_VERSION):
            raise ValueError(f'{db_path} has schema version {schema}; this server '
                             f'reads version {SUPPORTED_SCHEMA_VERSION}. Rebuild it.')
        self.namespace = meta.get('dataset_namespace', 'opentdb')
        self.license = meta.get('license')
        self.attribution = meta.get('attribution')
        with self._questions() as conn:
            self.max_id = conn.execute('SELECT MAX(id) FROM questions').fetchone()[0] or 0
            self.categories = [row[0] for row in conn.execute(
                'SELECT DISTINCT category FROM questions ORDER BY category')]

        # Trivia keys are text, unlike clue keys, so they get a table of their own.
        self.reported = load_reported(self.reports_path, '''
            CREATE TABLE IF NOT EXISTS reported_trivia (
              key         TEXT PRIMARY KEY,
              reported_at TEXT NOT NULL)''', 'SELECT key FROM reported_trivia')

    def _questions(self):
        # One connection per call: the server handles requests on many threads.
        return contextlib.closing(sqlite3.connect(self.db_uri, uri=True))

    def _reports(self):
        return contextlib.closing(sqlite3.connect(self.reports_path))

    def random(self, count, categories=None, difficulties=None):
        """Up to count distinct questions, each equally likely among those matching."""
        where, args = [], []
        if categories:
            where.append(f'category IN ({", ".join("?" * len(categories))})')
            args.extend(sorted(categories))
        if difficulties:
            where.append(f'difficulty IN ({", ".join("?" * len(difficulties))})')
            args.extend(sorted(difficulties))
        condition = f'WHERE {" AND ".join(where)}' if where else ''
        with self._questions() as conn:
            conn.row_factory = sqlite3.Row
            key = (condition, tuple(args))
            with self._lock:
                total = self._counts.get(key)
            if total is None:
                total = conn.execute(f'SELECT COUNT(*) FROM questions {condition}', args).fetchone()[0]
                with self._lock:
                    self._counts[key] = total
            found = []
            # Enough places to skip every reported question and still fill the batch.
            for offset in self.rng.sample(range(total), min(total, count + len(self.reported))):
                row = conn.execute(f'SELECT * FROM questions {condition} ORDER BY id '
                                   'LIMIT 1 OFFSET ?', [*args, offset]).fetchone()
                if row['key'] not in self.reported:
                    found.append(_trivia_to_json(row))
                    if len(found) == count:
                        break
        return found

    def random_from_query(self, query):
        """Takes count, category (repeated, one name each) and difficulty=easy,hard."""
        params = parse_qs(query, keep_blank_values=True)
        count = parse_count({k: v[-1] for k, v in params.items()})
        categories = {c for c in params.get('category', []) if c} or None
        difficulties = None
        if params.get('difficulty', [''])[-1]:
            difficulties = set(params['difficulty'][-1].split(','))
            if not difficulties <= set(self.difficulties):
                raise BadRequest('difficulty must be a comma-separated list of '
                                 + ', '.join(self.difficulties))
        return self.random(count, categories, difficulties)

    def parse_key(self, text):
        return text

    def info(self):
        info = {'namespace': self.namespace, 'kind': self.kind, 'filters': self.filters,
                'count': self.max_id, 'categories': self.categories}
        if self.license:
            info['license'] = self.license
        if self.attribution:
            info['attribution'] = self.attribution
        return info

    def report(self, key):
        """Records a report; returns False if no question has that key."""
        with self._questions() as conn:
            if conn.execute('SELECT 1 FROM questions WHERE key = ?', (key,)).fetchone() is None:
                return False
        now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
        with self._lock, self._reports() as conn:
            conn.execute('INSERT OR IGNORE INTO reported_trivia (key, reported_at) VALUES (?, ?)',
                         (key, now))
            conn.commit()
            self.reported.add(key)
        return True


# --- Score history (docs/history-plan.md section 4) ---------------------------

HISTORY_SCHEMA_VERSION = 1
MAX_HISTORY_BODY = 1024 * 1024
MAX_HISTORY_ANSWERS = 500
MAX_HISTORY_GAMES = 100
MAX_HISTORY_PAGE = 1000
HISTORY_FORMATS = ('open', 'multiple_choice', 'true_false')

HISTORY_SCHEMA = (
    '''CREATE TABLE IF NOT EXISTS answers (
         id TEXT PRIMARY KEY, seq INTEGER NOT NULL UNIQUE, game TEXT NOT NULL,
         answered_at TEXT NOT NULL, utc_offset INTEGER NOT NULL,
         namespace TEXT NOT NULL, question_key TEXT NOT NULL, category TEXT NOT NULL,
         format TEXT NOT NULL, round INTEGER, board_row INTEGER, value INTEGER,
         daily_double INTEGER NOT NULL, difficulty TEXT, correct INTEGER NOT NULL,
         received_at TEXT NOT NULL)''',
    '''CREATE TABLE IF NOT EXISTS games (
         id TEXT PRIMARY KEY, seq INTEGER NOT NULL UNIQUE,
         started TEXT, updated_at TEXT NOT NULL,
         answered INTEGER NOT NULL, correct INTEGER NOT NULL, best INTEGER NOT NULL,
         dollars INTEGER NOT NULL, valued INTEGER NOT NULL)''',
    'CREATE TABLE IF NOT EXISTS meta (name TEXT PRIMARY KEY, value TEXT NOT NULL)',
)

# Columns as stored, and the JSON name of each where it differs: key, row and
# right are SQL keywords.
ANSWER_COLUMNS = ('id', 'game', 'answered_at', 'utc_offset', 'namespace', 'question_key',
                  'category', 'format', 'round', 'board_row', 'value', 'daily_double',
                  'difficulty', 'correct')
GAME_COLUMNS = ('id', 'started', 'updated_at', 'answered', 'correct', 'best', 'dollars',
                'valued')
JSON_NAMES = {'question_key': 'key', 'board_row': 'row', 'correct': 'right'}
# Answers' true-or-false columns; a game's correct is a count.
ANSWER_BOOLEANS = {'daily_double', 'correct'}

_HISTORY_ID = re.compile(r'[0-9a-f]{32}')
_UTC_TIME = re.compile(r'(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d{1,9}))?Z')


class HistoryStore:
    """Every answer and game the player's devices send.

    Rows are kept as sent. Each row inserted or changed gets the next seq, a
    counter shared by both tables, so a device fetches what changed since it
    last asked. The history id is made with the database; a device that sees
    it change knows the history was replaced and starts again.
    """

    def __init__(self, path):
        self.path = Path(path)
        self._lock = threading.Lock()
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self._transaction() as conn:
                for statement in HISTORY_SCHEMA:
                    conn.execute(statement)
                for name, value in (('schema_version', str(HISTORY_SCHEMA_VERSION)),
                                    ('last_seq', '0'), ('history_id', secrets.token_hex(16))):
                    conn.execute('INSERT OR IGNORE INTO meta (name, value) VALUES (?, ?)',
                                 (name, value))
                meta = dict(conn.execute('SELECT name, value FROM meta'))
        except (OSError, sqlite3.Error) as e:
            raise StorageUnavailable(
                f'cannot keep the score history in {self.path.resolve()}: {e}') from e
        if meta['schema_version'] != str(HISTORY_SCHEMA_VERSION):
            raise ValueError(f'{self.path} has history schema version '
                             f'{meta["schema_version"]}; this server reads version '
                             f'{HISTORY_SCHEMA_VERSION}.')
        self.history_id = meta['history_id']

    @contextlib.contextmanager
    def _transaction(self):
        # BEGIN IMMEDIATE takes the write lock up front, so two servers on one
        # file (clues and trivia) can't hand out the same seq.
        conn = sqlite3.connect(self.path, timeout=10, isolation_level=None)
        conn.row_factory = sqlite3.Row
        try:
            conn.execute('BEGIN IMMEDIATE')
            try:
                yield conn
            except BaseException:
                conn.execute('ROLLBACK')
                raise
            conn.execute('COMMIT')
        finally:
            conn.close()

    def put(self, body):
        """Stores an upload, parsed by parse_history_upload. An answer replaces
        one with the same id; a game row replaces one that isn't newer."""
        answers, games = body
        now = _utc_now()
        with self._lock, self._transaction() as conn:
            seq = int(conn.execute("SELECT value FROM meta WHERE name = 'last_seq'")
                      .fetchone()[0])
            for answer in answers:
                old = conn.execute('SELECT * FROM answers WHERE id = ?',
                                   (answer['id'],)).fetchone()
                if old is not None and all(old[c] == answer[c] for c in ANSWER_COLUMNS):
                    continue
                seq += 1
                conn.execute(f'''INSERT OR REPLACE INTO answers
                                 ({", ".join(ANSWER_COLUMNS)}, seq, received_at)
                                 VALUES ({", ".join("?" * (len(ANSWER_COLUMNS) + 2))})''',
                             [answer[c] for c in ANSWER_COLUMNS] + [seq, now])
            for game in games:
                old = conn.execute('SELECT * FROM games WHERE id = ?', (game['id'],)).fetchone()
                if old is not None and (old['updated_at'] > game['updated_at'] or
                                        all(old[c] == game[c] for c in GAME_COLUMNS)):
                    continue
                seq += 1
                conn.execute(f'''INSERT OR REPLACE INTO games ({", ".join(GAME_COLUMNS)}, seq)
                                 VALUES ({", ".join("?" * (len(GAME_COLUMNS) + 1))})''',
                             [game[c] for c in GAME_COLUMNS] + [seq])
            conn.execute("UPDATE meta SET value = ? WHERE name = 'last_seq'", (str(seq),))

    def changes(self, after=0, limit=MAX_HISTORY_PAGE):
        """The answers and games changed after seq `after`, at most `limit` rows."""
        with self._lock, self._transaction() as conn:
            rows = []
            for table, columns, booleans in (('answers', ANSWER_COLUMNS, ANSWER_BOOLEANS),
                                             ('games', GAME_COLUMNS, set())):
                rows += [(row['seq'], table, _history_json(row, columns, booleans))
                         for row in conn.execute(
                    f'SELECT * FROM {table} WHERE seq > ? ORDER BY seq LIMIT ?',
                    (after, limit + 1))]
        rows.sort(key=lambda r: r[0])
        page = rows[:limit]
        return {
            'history': self.history_id,
            'answers': [item for _, table, item in page if table == 'answers'],
            'games': [item for _, table, item in page if table == 'games'],
            'next': page[-1][0] if page else after,
            'more': len(rows) > limit,
        }


def _utc_now():
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.strftime('%Y-%m-%dT%H:%M:%S.') + f'{now.microsecond // 1000:03d}Z'


def _history_json(row, columns, booleans):
    return {JSON_NAMES.get(c, c): bool(row[c]) if c in booleans else row[c]
            for c in columns}


def parse_history_upload(data):
    """The answers and games of a POST /v1/history body, checked and in column
    form. Raises BadRequest naming the first problem, or TooLarge."""
    try:
        body = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise BadRequest('the body is not JSON')
    if not isinstance(body, dict):
        raise BadRequest('the body must be an object with "answers" and "games"')
    answers, games = body.get('answers', []), body.get('games', [])
    if not isinstance(answers, list) or not isinstance(games, list):
        raise BadRequest('"answers" and "games" must be lists')
    if len(answers) > MAX_HISTORY_ANSWERS or len(games) > MAX_HISTORY_GAMES:
        raise TooLarge(f'send at most {MAX_HISTORY_ANSWERS} answers and '
                       f'{MAX_HISTORY_GAMES} games at a time')
    return ([_parse_answer(a, f'answers[{i}]') for i, a in enumerate(answers)],
            [_parse_game(g, f'games[{i}]') for i, g in enumerate(games)])


def _parse_answer(item, where):
    f = _Fields(item, where)
    return {
        'id': f.id('id'),
        'game': f.id('game'),
        'answered_at': f.utc_time('answered_at'),
        'utc_offset': f.int('utc_offset', -16 * 60, 16 * 60),
        'namespace': f.text('namespace', 1, 100),
        'question_key': f.text('key', 1, 200),
        'category': f.text('category', 0, 300),
        'format': f.choice('format', HISTORY_FORMATS),
        'round': f.int('round', 1, 3, optional=True),
        'board_row': f.int('row', 1, 5, optional=True),
        'value': f.int('value', 0, 1_000_000, optional=True),
        'daily_double': f.bool('daily_double'),
        'difficulty': f.text('difficulty', 1, 20, optional=True),
        'correct': f.bool('right'),
    }


def _parse_game(item, where):
    f = _Fields(item, where)
    game = {
        'id': f.id('id'),
        'started': f.date('started', optional=True),
        'updated_at': f.utc_time('updated_at'),
        'answered': f.int('answered', 0, 10_000_000),
        'correct': f.int('right', 0, 10_000_000),
        'best': f.int('best', 0, 10_000_000),
        'dollars': f.int('dollars', -10**12, 10**12),
        'valued': f.int('valued', 0, 10_000_000),
    }
    if not (game['correct'] <= game['answered'] and game['valued'] <= game['answered']
            and game['best'] <= game['correct']):
        raise BadRequest(f'{where} has counts that can\'t go together')
    return game


class _Fields:
    """Reads one checked field at a time from a JSON object."""

    def __init__(self, item, where):
        if not isinstance(item, dict):
            raise BadRequest(f'{where} must be an object')
        self.item, self.where = item, where

    def _get(self, name, optional):
        value = self.item.get(name)
        if value is None and not optional:
            raise BadRequest(f'{self.where}.{name} is missing')
        return value

    def _bad(self, name, what):
        return BadRequest(f'{self.where}.{name} must be {what}')

    def id(self, name):
        value = self._get(name, False)
        if not isinstance(value, str) or not _HISTORY_ID.fullmatch(value):
            raise self._bad(name, '32 lowercase hex digits')
        return value

    def text(self, name, shortest, longest, optional=False):
        value = self._get(name, optional)
        if value is not None and (not isinstance(value, str)
                                  or not shortest <= len(value) <= longest):
            raise self._bad(name, f'text of {shortest} to {longest} characters')
        return value

    def choice(self, name, choices):
        value = self._get(name, False)
        if value not in choices:
            raise self._bad(name, 'one of ' + ', '.join(choices))
        return value

    def int(self, name, lowest, highest, optional=False):
        value = self._get(name, optional)
        if value is not None and (type(value) is not int or not lowest <= value <= highest):
            raise self._bad(name, f'a whole number from {lowest} to {highest}')
        return value

    def bool(self, name):
        value = self._get(name, False)
        if type(value) is not bool:
            raise self._bad(name, 'true or false')
        return value

    def utc_time(self, name):
        value = self._get(name, False)
        match = _UTC_TIME.fullmatch(value) if isinstance(value, str) else None
        try:
            if match is None:
                raise ValueError
            parts = [int(g) for g in match.groups()[:6]]
            fraction = (match.group(7) or '0').ljust(3, '0')[:3]
            datetime.datetime(*parts)
        except ValueError:
            raise self._bad(name, 'a UTC time such as 2026-10-13T18:35:10.123Z') from None
        return '%04d-%02d-%02dT%02d:%02d:%02d.%sZ' % (*parts, fraction)

    def date(self, name, optional=False):
        value = self._get(name, optional)
        if value is None:
            return None
        try:
            if not isinstance(value, str):
                raise ValueError
            return datetime.date.fromisoformat(value).isoformat()
        except ValueError:
            raise self._bad(name, 'a date such as 2026-10-13') from None


def parse_history_query(query):
    """after and limit from a GET /v1/history query string."""
    params = parse_qs(query)
    try:
        after = int(params.get('after', ['0'])[-1])
        limit = int(params.get('limit', [str(MAX_HISTORY_PAGE)])[-1])
    except ValueError:
        raise BadRequest('after and limit must be whole numbers')
    if after < 0 or not 1 <= limit <= MAX_HISTORY_PAGE:
        raise BadRequest(f'after must be 0 or more, and limit from 1 to {MAX_HISTORY_PAGE}')
    return after, limit


def _trivia_to_json(row):
    return {
        'key': row['key'],
        'category': row['category'],
        'clue': row['question'],
        'response': row['answer'],
        'choices': json.loads(row['choices']),
        'difficulty': row['difficulty'],
    }


def _to_json(row):
    return {
        # A string: 64-bit keys aren't safe as JSON numbers for every client.
        'key': str(row['clue_key']),
        'category': row['category'],
        'category_comment': row['category_comment'],
        'clue': row['clue'],
        'response': row['response'],
        'value': row['value'],
        'round': row['round'],
        'dd_wager': row['dd_wager'],
        'air_date': row['air_date'],
        'notes': row['notes'],
    }


def parse_count(params):
    """The count parameter, capped at MAX_COUNT; DEFAULT_COUNT if absent."""
    try:
        count = int(params.get('count', DEFAULT_COUNT))
    except ValueError:
        raise BadRequest('count must be a number')
    if count < 1:
        raise BadRequest('count must be at least 1')
    return min(count, MAX_COUNT)


def parse_random_query(query):
    """Parses /v1/random's query string for clues. Unknown parameters are ignored."""
    params = {k: v[-1] for k, v in parse_qs(query, keep_blank_values=True).items()}
    count = parse_count(params)
    rounds = None
    if params.get('round'):
        try:
            rounds = {int(r) for r in params['round'].split(',')}
        except ValueError:
            raise BadRequest('round must be a comma-separated list of 1, 2 and 3')
        if not rounds <= {1, 2, 3}:
            raise BadRequest('round must be a comma-separated list of 1, 2 and 3')
    rows = None
    if params.get('row'):
        try:
            rows = {int(r) for r in params['row'].split(',')}
        except ValueError:
            raise BadRequest('row must be a comma-separated list of 1 to 5')
        if not rows <= {1, 2, 3, 4, 5}:
            raise BadRequest('row must be a comma-separated list of 1 to 5')
    dates = {}
    for name in ('from', 'to'):
        if params.get(name):
            try:
                dates[name] = datetime.date.fromisoformat(params[name]).isoformat()
            except ValueError:
                raise BadRequest(f'{name} must be a date like 2004-03-01')
    return count, rounds, dates.get('from'), dates.get('to'), rows


def web_file(root, url_path):
    """The file under root that url_path names, or None.

    root must be resolved. Hidden names, `..` and anything that resolves
    outside root (through a symlink, say) are refused.
    """
    rel = unquote(url_path).lstrip('/') or 'index.html'
    if any(part.startswith('.') for part in rel.split('/')) or '\\' in rel:
        return None
    try:
        path = (root / rel).resolve()
        if not path.is_relative_to(root) or not path.is_file():
            return None
    except (OSError, ValueError):  # ValueError: a NUL byte in the name.
        return None
    return path


def web_build_uses_cdn(web_root):
    """Whether a Flutter web build loads CanvasKit and fonts from Google's CDN.

    By default `flutter build web` does, so the page only works with internet
    access; --no-web-resources-cdn bundles them.
    """
    try:
        bootstrap = (Path(web_root) / 'flutter_bootstrap.js').read_text(errors='replace')
    except OSError:
        return False
    return '"useLocalCanvasKit":true' not in bootstrap.replace(' ', '')


def make_handler(store, token=None, quiet=False, web_root=None, history=None):
    class Handler(BaseHTTPRequestHandler):
        server_version = 'serve_clues/1'

        def do_GET(self):
            self._handle('GET')

        def do_HEAD(self):
            self._handle('HEAD')

        def do_POST(self):
            self._handle('POST')

        def _handle(self, method):
            url = urlsplit(self.path)
            parts = [unquote(p) for p in url.path.split('/') if p]
            if parts[:1] != ['v1']:
                if web_root is not None:
                    return self._serve_web(method, url.path)
                return self._send_json(HTTPStatus.NOT_FOUND, {'error': 'not found'})
            if token is not None and not self._authorized():
                return self._send_json(HTTPStatus.UNAUTHORIZED,
                                       {'error': 'missing or wrong bearer token'})
            try:
                if parts == ['v1', 'info']:
                    if method != 'GET':
                        return self._not_allowed('GET')
                    info = store.info()
                    if history is not None:
                        info['history'] = True
                    return self._send_json(HTTPStatus.OK, info)
                if parts == ['v1', 'history'] and history is not None:
                    if method == 'GET':
                        return self._send_json(HTTPStatus.OK, history.changes(
                            *parse_history_query(url.query)))
                    if method != 'POST':
                        return self._not_allowed('GET, POST')
                    history.put(parse_history_upload(self._read_body(MAX_HISTORY_BODY)))
                    return self._send(HTTPStatus.NO_CONTENT)
                if parts == ['v1', 'random']:
                    if method != 'GET':
                        return self._not_allowed('GET')
                    questions = store.random_from_query(url.query)
                    return self._send_json(HTTPStatus.OK,
                                           {'namespace': store.namespace, 'questions': questions})
                if len(parts) == 4 and parts[:2] == ['v1', 'questions'] and parts[3] == 'report':
                    if method != 'POST':
                        return self._not_allowed('POST')
                    key = store.parse_key(parts[2])
                    if not store.report(key):
                        return self._send_json(HTTPStatus.NOT_FOUND, {'error': 'no such question'})
                    return self._send(HTTPStatus.NO_CONTENT)
            except BadRequest as e:
                return self._send_json(HTTPStatus.BAD_REQUEST, {'error': str(e)})
            except TooLarge as e:
                return self._send_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {'error': str(e)})
            return self._send_json(HTTPStatus.NOT_FOUND, {'error': 'not found'})

        def _read_body(self, limit):
            try:
                length = int(self.headers.get('Content-Length', 0))
            except ValueError:
                raise BadRequest('Content-Length must be a number')
            if length > limit:
                # The body is left unread, so the connection can't be reused.
                self.close_connection = True
                raise TooLarge(f'the body must be at most {limit} bytes')
            return self.rfile.read(length)

        def _serve_web(self, method, url_path):
            if method not in ('GET', 'HEAD'):
                return self._not_allowed('GET, HEAD')
            path = web_file(web_root, url_path)
            if path is None:
                return self._send(HTTPStatus.NOT_FOUND, b'Not found',
                                  {'Content-Type': 'text/plain; charset=utf-8'})
            stat = path.stat()
            # no-cache: the browser keeps its copy but checks it on every load,
            # so a rebuilt app shows up on reload. Unchanged files get a 304.
            headers = {'Cache-Control': 'no-cache',
                       'Last-Modified': email.utils.formatdate(stat.st_mtime, usegmt=True),
                       'X-Content-Type-Options': 'nosniff'}
            if self._not_modified_since(stat.st_mtime):
                return self._send(HTTPStatus.NOT_MODIFIED, headers=headers)
            content_type = (WEB_CONTENT_TYPES.get(path.suffix.lower())
                            or mimetypes.guess_type(path.name)[0]
                            or 'application/octet-stream')
            self._send(HTTPStatus.OK, path.read_bytes(),
                       {'Content-Type': content_type, **headers})

        def _not_modified_since(self, mtime):
            since = self.headers.get('If-Modified-Since')
            if not since:
                return False
            try:
                since = email.utils.parsedate_to_datetime(since)
            except (TypeError, ValueError):
                return False
            if since.tzinfo is None:
                return False
            return int(mtime) <= since.timestamp()

        def _authorized(self):
            expected = f'Bearer {token}'.encode()
            actual = self.headers.get('Authorization', '').encode()
            return hmac.compare_digest(actual, expected)

        def _not_allowed(self, allowed):
            self._send_json(HTTPStatus.METHOD_NOT_ALLOWED, {'error': 'method not allowed'},
                            {'Allow': allowed})

        def _send_json(self, status, body, headers=None):
            data = json.dumps(body, ensure_ascii=False).encode('utf-8')
            self._send(status, data, {'Content-Type': 'application/json; charset=utf-8',
                                      **(headers or {})})

        def _send(self, status, data=b'', headers=None):
            self.send_response(status)
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            if status != HTTPStatus.NOT_MODIFIED:
                self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            if self.command != 'HEAD' and status != HTTPStatus.NOT_MODIFIED:
                self.wfile.write(data)

        def log_message(self, format, *args):
            if not quiet:
                super().log_message(format, *args)

    return Handler


def make_server(store, host='127.0.0.1', port=8080, token=None, quiet=False, web_root=None,
                history=None):
    """web_root, if given, is a Flutter web build to serve outside /v1/; history, a
    HistoryStore for /v1/history."""
    if web_root is not None:
        web_root = Path(web_root).resolve()
    return ThreadingHTTPServer((host, port),
                               make_handler(store, token, quiet, web_root, history))


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--db', type=Path, default=os.environ.get('QUIZ_DB') or DEFAULT_DB,
                        help='clue or trivia database to serve; QUIZ_DB if set '
                             '(default: %(default)s)')
    parser.add_argument('--reports', type=Path, default=DEFAULT_REPORTS,
                        help='where reported clues are kept (default: %(default)s)')
    parser.add_argument('--history', type=Path, default=DEFAULT_HISTORY,
                        help='where the score history is kept (default: %(default)s)')
    parser.add_argument('--host', default='127.0.0.1',
                        help='address to listen on; 0.0.0.0 for your whole network '
                             '(default: %(default)s)')
    parser.add_argument('--port', type=int, default=8080,
                        help='port to listen on; 0 picks a free one (default: %(default)s)')
    parser.add_argument('--token', default=os.environ.get('QUIZ_TOKEN') or None,
                        help='require this bearer token (QUESTION_API_TOKEN in the app); '
                             'QUIZ_TOKEN if set')
    parser.add_argument('--web', type=Path, metavar='DIR',
                        help='also serve the web UI from this Flutter web build '
                             '(build/web after flutter build web --no-web-resources-cdn)')
    parser.add_argument('--quiet', action='store_true', help="don't log each request")
    return parser.parse_args(argv)


def _stop(signum, frame):
    raise KeyboardInterrupt


def main(argv=None):
    args = parse_args(argv)
    if not args.db.exists():
        print(f'error: {args.db} does not exist. Run python3 tool/build_clue_db.py '
              '(or tool/build_trivia_db.py) first.', file=sys.stderr)
        return 1
    if args.web is not None and not (args.web / 'index.html').is_file():
        print(f'error: {args.web} has no index.html. Run '
              'flutter build web --no-web-resources-cdn first.', file=sys.stderr)
        return 1
    try:
        store = open_store(args.db, args.reports)
        history = HistoryStore(args.history)
    except (ValueError, sqlite3.Error, StorageUnavailable) as e:
        print(f'error: {e}', file=sys.stderr)
        return 1
    server = make_server(store, args.host, args.port, args.token, args.quiet, args.web,
                         history)
    host, port = server.server_address[:2]
    noun = 'clues' if store.kind == 'clues' else 'trivia questions'
    print(f'Serving {store.max_id} {noun} on http://{host}:{port}/v1/random', flush=True)
    if args.web is not None:
        print(f'Web UI on http://{host}:{port}/', flush=True)
        if web_build_uses_cdn(args.web):
            print(f'Warning: {args.web} loads CanvasKit and fonts from Google, so browsers '
                  'without internet access show a blank page. Rebuild it with '
                  'flutter build web --no-web-resources-cdn.', flush=True)
    if args.host not in ('127.0.0.1', 'localhost', '::1') and store.license is None:
        print('Personal use only: keep this server off the internet (see the dataset terms '
              'in README.md).' + ('' if args.token else ' Consider --token.'), flush=True)
    # docker stop sends SIGTERM, which a container's first process ignores
    # unless it has a handler; stop as Ctrl-C does.
    signal.signal(signal.SIGTERM, _stop)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
