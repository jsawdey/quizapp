#!/usr/bin/env python3
"""Serve the clue and trivia databases over HTTP, using the app's `quizapp` API (v1).

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
    python3 tool/serve_clues.py --db assets/db/clues.db --db assets/db/trivia.db  # both

Then build the app with QUESTION_SOURCE=api (or api_with_local_fallback),
QUESTION_API_DIALECT=quizapp and QUESTION_API_URL=http://<this computer>:8080.
Release builds need https; see README.md. With --web, after
flutter build web --no-web-resources-cdn, browsers can play at
http://<this computer>:8080/.

API (docs/question-backend-plan.md section 7):
    GET  /v1/info      what is served: kind, filters, categories, credit, and
                       every database on this server ("datasets")
    GET  /v1/random?count=10[&round=1,2][&from=YYYY-MM-DD][&to=YYYY-MM-DD][&row=4,5]
    GET  /v1/random?count=10[&category=Art&category=History][&difficulty=easy,hard]
         (trivia; an empty "questions" list when nothing matches the filters)
    POST /v1/questions/{key}/report

With several --db, the first is served under /v1/ and each one under its file
name as well: /clues/v1/random, /trivia/v1/random. The app lists them all and
switches between them (docs/combined-server-plan.md).

With --token, the API needs the bearer token but the web UI's files don't:
they hold no clues, and the page asks for the token.

The environment variables QUIZ_DB (comma-separated paths) and QUIZ_TOKEN, if
set, stand in for --db and --token (the Docker image uses them; see
docs/docker-plan.md).

Reported questions are kept in a separate database (--reports) and never
served again, so hiding one on one device hides it on all of them.

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

SUPPORTED_SCHEMA_VERSION = 1
MAX_COUNT = 50
DEFAULT_COUNT = 10
# Random picks to try per requested clue before returning fewer than asked.
ATTEMPTS_PER_CLUE = 5
# What a database's name, its file name without .db, may be when there are
# several: it becomes a path segment (docs/combined-server-plan.md section 2).
DATASET_NAME = re.compile(r'[a-z0-9][a-z0-9_-]*')

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


class ReportsUnavailable(Exception):
    """The reports database can't be created or opened."""


def load_reported(reports_path, create_table, select_keys):
    """Creates the reported-question table if needed; returns the reported keys."""
    try:
        reports_path.parent.mkdir(parents=True, exist_ok=True)
        with contextlib.closing(sqlite3.connect(reports_path)) as conn:
            conn.execute(create_table)
            return {row[0] for row in conn.execute(select_keys)}
    except (OSError, sqlite3.Error) as e:
        # Often a Docker volume owned by another user (docs/docker-plan.md).
        raise ReportsUnavailable(
            f'cannot keep reported questions in {reports_path.resolve()}: {e}') from e


class BadRequest(Exception):
    pass


def read_meta(db_path):
    """The meta table of the database at db_path, opened read-only."""
    uri = Path(db_path).resolve().as_uri() + '?mode=ro'
    with contextlib.closing(sqlite3.connect(uri, uri=True)) as conn:
        return dict(conn.execute('SELECT key, value FROM meta'))


def open_store(db_path, reports_path, rng=None):
    """A ClueStore or TriviaStore, as the database's dataset_kind says.

    Its name is the file's name without the extension.
    """
    if read_meta(db_path).get('dataset_kind') == 'trivia':
        store = TriviaStore(db_path, reports_path, rng)
    else:
        store = ClueStore(db_path, reports_path, rng)
    store.name = Path(db_path).stem
    return store


def open_stores(db_paths, reports_path, rng=None):
    """The stores for db_paths by name, in order; the first is the default.

    All of them keep their reports in reports_path. With more than one, each
    name must be a path segment of its own: lower case and unique, and not
    v1. Raises ValueError if not.
    """
    if len(db_paths) > 1:
        names = [Path(path).stem for path in db_paths]
        for path, name in zip(db_paths, names):
            if not DATASET_NAME.fullmatch(name) or name == 'v1':
                raise ValueError(f'{path}: to serve several databases, each file name '
                                 'must be lower-case letters, digits, - and _ before .db '
                                 '(and not v1.db). Rename it.')
            if names.count(name) > 1:
                raise ValueError(f'more than one database is called {name}.db; rename one.')
    stores = {}
    for path in db_paths:
        try:
            store = open_store(path, reports_path, rng)
        except sqlite3.Error as e:
            raise ValueError(f'cannot open {path}: {e}') from e
        stores[store.name] = store
    return stores


def unreadable(db_path):
    """Why the server can't read db_path, or None if it can."""
    if os.access(db_path, os.R_OK):
        return None
    reason = f'cannot read {db_path}: permission denied.'
    if hasattr(os, 'getuid'):
        owner = Path(db_path).stat().st_uid
        reason += (f' It belongs to user {owner}, and this server runs as user '
                   f'{os.getuid()}.')
    return (reason + ' Make it readable to everyone (chmod a+r on it), or build it '
            'again as this user, as docker compose run does.')


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


def datasets(stores, prefix):
    """The databases on this server, for /v1/info at the base /{prefix}/.

    Each path is relative to that base, so it holds behind a proxy that adds
    a prefix of its own. The default (first) database is always the root.
    """
    root = '../' if prefix is not None else ''
    default = next(iter(stores))
    listed = []
    for name, store in stores.items():
        if name == default:
            path = root or './'
        elif name == prefix:
            path = './'
        else:
            path = f'{root}{name}/'
        listed.append({'name': name, 'kind': store.kind, 'count': store.max_id, 'path': path})
    return listed


def make_handler(stores, token=None, quiet=False, web_root=None):
    """stores: the stores by name, the default first."""
    default = next(iter(stores.values()))

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
            # /v1/... is the default database; /{name}/v1/... any of them.
            if parts[:1] == ['v1']:
                store, prefix = default, None
            elif len(parts) >= 2 and parts[1] == 'v1' and parts[0] in stores:
                store, prefix = stores[parts[0]], parts[0]
                parts = parts[1:]
            else:
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
                    return self._send_json(HTTPStatus.OK,
                                           {**store.info(), 'datasets': datasets(stores, prefix)})
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
            return self._send_json(HTTPStatus.NOT_FOUND, {'error': 'not found'})

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


def make_server(stores, host='127.0.0.1', port=8080, token=None, quiet=False, web_root=None):
    """stores: from open_stores, or a single store. web_root, if given, is a
    Flutter web build to serve outside the API."""
    if not isinstance(stores, dict):
        stores = {stores.name: stores}
    if web_root is not None:
        web_root = Path(web_root).resolve()
    return ThreadingHTTPServer((host, port), make_handler(stores, token, quiet, web_root))


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--db', type=Path, action='append',
                        help='clue or trivia database to serve; give it more than once to '
                             'serve several, the first by default. QUIZ_DB (comma-separated) '
                             f'if set (default: {DEFAULT_DB})')
    parser.add_argument('--reports', type=Path, default=DEFAULT_REPORTS,
                        help='where reported clues are kept (default: %(default)s)')
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
    args = parser.parse_args(argv)
    if args.db is None:
        listed = [Path(p.strip()) for p in os.environ.get('QUIZ_DB', '').split(',') if p.strip()]
        args.db = listed or [DEFAULT_DB]
    return args


def _stop(signum, frame):
    raise KeyboardInterrupt


def main(argv=None):
    args = parse_args(argv)
    for db in args.db:
        if not db.exists():
            parts = [Path(part) for part in str(db).split(':') if part]
            if len(parts) > 1 and any(part.exists() for part in parts):
                hint = 'To serve several databases, separate them with commas, not colons.'
            else:
                hint = 'Run python3 tool/build_clue_db.py (or tool/build_trivia_db.py) first.'
            print(f'error: {db} does not exist. {hint}', file=sys.stderr)
            return 1
        reason = unreadable(db)
        if reason is not None:
            print(f'error: {reason}', file=sys.stderr)
            return 1
    if args.web is not None and not (args.web / 'index.html').is_file():
        print(f'error: {args.web} has no index.html. Run '
              'flutter build web --no-web-resources-cdn first.', file=sys.stderr)
        return 1
    try:
        stores = open_stores(args.db, args.reports)
    except (ValueError, sqlite3.Error, ReportsUnavailable) as e:
        print(f'error: {e}', file=sys.stderr)
        return 1
    server = make_server(stores, args.host, args.port, args.token, args.quiet, args.web)
    host, port = server.server_address[:2]
    for i, (name, store) in enumerate(stores.items()):
        noun = 'clues' if store.kind == 'clues' else 'trivia questions'
        if i == 0:
            also = f' (also /{name}/v1/random)' if len(stores) > 1 else ''
            where = f'/v1/random{also}'
        else:
            where = f'/{name}/v1/random'
        print(f'Serving {store.max_id} {noun} on http://{host}:{port}{where}', flush=True)
    if args.web is not None:
        print(f'Web UI on http://{host}:{port}/', flush=True)
        if web_build_uses_cdn(args.web):
            print(f'Warning: {args.web} loads CanvasKit and fonts from Google, so browsers '
                  'without internet access show a blank page. Rebuild it with '
                  'flutter build web --no-web-resources-cdn.', flush=True)
    unlicensed = any(store.license is None for store in stores.values())
    if args.host not in ('127.0.0.1', 'localhost', '::1') and unlicensed:
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
