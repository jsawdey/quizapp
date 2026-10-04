#!/usr/bin/env python3
"""Serve the clue database over HTTP, using the app's `quizapp` API (v1).

The dataset is property of Jeopardy Productions, Inc. and its author asks that
it not be used for public-facing apps or products. This server is for your own
devices only: keep it on localhost or your home network, never the internet.

Usage (from the repository root, after python3 tool/build_clue_db.py):
    python3 tool/serve_clues.py                              # localhost only
    python3 tool/serve_clues.py --host 0.0.0.0 --token SECRET  # your LAN
    python3 tool/serve_clues.py --web build/web              # plus the web UI

Then build the app with QUESTION_SOURCE=api (or api_with_local_fallback),
QUESTION_API_DIALECT=quizapp and QUESTION_API_URL=http://<this computer>:8080.
Release builds need https; see README.md. With --web, after
flutter build web --no-web-resources-cdn, browsers can play at
http://<this computer>:8080/.

API (docs/question-backend-plan.md section 7):
    GET  /v1/random?count=10[&round=1,2][&from=YYYY-MM-DD][&to=YYYY-MM-DD]
    POST /v1/questions/{key}/report

With --token, the API needs the bearer token but the web UI's files don't:
they hold no clues, and the page asks for the token.

Reported clues are kept in a separate database (--reports) and never served
again, so hiding a clue on one device hides it on all of them.

Only the Python standard library is required.
"""

import argparse
import contextlib
import datetime
import email.utils
import hmac
import json
import mimetypes
import random
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


class BadRequest(Exception):
    pass


class ClueStore:
    """Read-only access to the clue database plus the reported-clue list."""

    def __init__(self, db_path, reports_path, rng=None):
        self.db_uri = Path(db_path).resolve().as_uri() + '?mode=ro'
        self.reports_path = Path(reports_path)
        self.rng = rng or random.Random()
        self._lock = threading.Lock()

        with self._clues() as conn:
            meta = dict(conn.execute('SELECT key, value FROM meta'))
            schema = meta.get('schema_version')
            if schema != str(SUPPORTED_SCHEMA_VERSION):
                raise ValueError(f'{db_path} has schema version {schema}; this server '
                                 f'reads version {SUPPORTED_SCHEMA_VERSION}. Rebuild it.')
            self.namespace = meta.get('dataset_namespace', 'jwolle1')
            self.max_id = conn.execute('SELECT MAX(id) FROM clues').fetchone()[0] or 0

        self.reports_path.parent.mkdir(parents=True, exist_ok=True)
        with self._reports() as conn:
            conn.execute('''CREATE TABLE IF NOT EXISTS reported (
                              clue_key    INTEGER PRIMARY KEY,
                              reported_at TEXT NOT NULL)''')
            self.reported = {row[0] for row in conn.execute('SELECT clue_key FROM reported')}

    def _clues(self):
        # One connection per call: the server handles requests on many threads.
        return contextlib.closing(sqlite3.connect(self.db_uri, uri=True))

    def _reports(self):
        return contextlib.closing(sqlite3.connect(self.reports_path))

    def random(self, count, rounds=None, date_from=None, date_to=None):
        if self.max_id == 0:
            return []
        where, args = ['c.id >= ?'], []
        if rounds is not None:
            where.append(f'c.round IN ({", ".join("?" * len(rounds))})')
            args.extend(sorted(rounds))
        if date_from is not None:
            where.append('g.air_date >= ?')
            args.append(date_from)
        if date_to is not None:
            where.append('g.air_date <= ?')
            args.append(date_to)
        sql = f'{SELECT} WHERE {" AND ".join(where)} ORDER BY c.id LIMIT 1'

        found = {}
        with self._clues() as conn:
            conn.row_factory = sqlite3.Row
            for _ in range(count * ATTEMPTS_PER_CLUE):
                if len(found) == count:
                    break
                start = self.rng.randint(1, self.max_id)
                row = conn.execute(sql, [start, *args]).fetchone()
                if row is None and start > 1:
                    row = conn.execute(sql, [1, *args]).fetchone()
                if row is None:
                    break  # Nothing matches the filter at all.
                if row['clue_key'] not in self.reported:
                    found.setdefault(row['clue_key'], row)
        return [_to_json(row) for row in found.values()]

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


def parse_random_query(query):
    """Parses /v1/random's query string. Unknown parameters are ignored."""
    params = {k: v[-1] for k, v in parse_qs(query, keep_blank_values=True).items()}
    try:
        count = int(params.get('count', DEFAULT_COUNT))
    except ValueError:
        raise BadRequest('count must be a number')
    if count < 1:
        raise BadRequest('count must be at least 1')
    rounds = None
    if params.get('round'):
        try:
            rounds = {int(r) for r in params['round'].split(',')}
        except ValueError:
            raise BadRequest('round must be a comma-separated list of 1, 2 and 3')
        if not rounds <= {1, 2, 3}:
            raise BadRequest('round must be a comma-separated list of 1, 2 and 3')
    dates = {}
    for name in ('from', 'to'):
        if params.get(name):
            try:
                dates[name] = datetime.date.fromisoformat(params[name]).isoformat()
            except ValueError:
                raise BadRequest(f'{name} must be a date like 2004-03-01')
    return min(count, MAX_COUNT), rounds, dates.get('from'), dates.get('to')


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


def make_handler(store, token=None, quiet=False, web_root=None):
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
                if parts == ['v1', 'random']:
                    if method != 'GET':
                        return self._not_allowed('GET')
                    count, rounds, date_from, date_to = parse_random_query(url.query)
                    questions = store.random(count, rounds, date_from, date_to)
                    return self._send_json(HTTPStatus.OK,
                                           {'namespace': store.namespace, 'questions': questions})
                if len(parts) == 4 and parts[:2] == ['v1', 'questions'] and parts[3] == 'report':
                    if method != 'POST':
                        return self._not_allowed('POST')
                    try:
                        key = int(parts[2])
                    except ValueError:
                        raise BadRequest('question keys are integers')
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


def make_server(store, host='127.0.0.1', port=8080, token=None, quiet=False, web_root=None):
    """web_root, if given, is a Flutter web build to serve outside /v1/."""
    if web_root is not None:
        web_root = Path(web_root).resolve()
    return ThreadingHTTPServer((host, port), make_handler(store, token, quiet, web_root))


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--db', type=Path, default=DEFAULT_DB,
                        help='clue database to serve (default: %(default)s)')
    parser.add_argument('--reports', type=Path, default=DEFAULT_REPORTS,
                        help='where reported clues are kept (default: %(default)s)')
    parser.add_argument('--host', default='127.0.0.1',
                        help='address to listen on; 0.0.0.0 for your whole network '
                             '(default: %(default)s)')
    parser.add_argument('--port', type=int, default=8080,
                        help='port to listen on; 0 picks a free one (default: %(default)s)')
    parser.add_argument('--token',
                        help='require this bearer token (QUESTION_API_TOKEN in the app)')
    parser.add_argument('--web', type=Path, metavar='DIR',
                        help='also serve the web UI from this Flutter web build '
                             '(build/web after flutter build web --no-web-resources-cdn)')
    parser.add_argument('--quiet', action='store_true', help="don't log each request")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if not args.db.exists():
        print(f'error: {args.db} does not exist. Run python3 tool/build_clue_db.py first.',
              file=sys.stderr)
        return 1
    if args.web is not None and not (args.web / 'index.html').is_file():
        print(f'error: {args.web} has no index.html. Run '
              'flutter build web --no-web-resources-cdn first.', file=sys.stderr)
        return 1
    try:
        store = ClueStore(args.db, args.reports)
    except (ValueError, sqlite3.Error) as e:
        print(f'error: {e}', file=sys.stderr)
        return 1
    server = make_server(store, args.host, args.port, args.token, args.quiet, args.web)
    host, port = server.server_address[:2]
    print(f'Serving {store.max_id} clues on http://{host}:{port}/v1/random', flush=True)
    if args.web is not None:
        print(f'Web UI on http://{host}:{port}/', flush=True)
        if web_build_uses_cdn(args.web):
            print(f'Warning: {args.web} loads CanvasKit and fonts from Google, so browsers '
                  'without internet access show a blank page. Rebuild it with '
                  'flutter build web --no-web-resources-cdn.', flush=True)
    if args.host not in ('127.0.0.1', 'localhost', '::1'):
        print('Personal use only: keep this server off the internet (see the dataset terms '
              'in README.md).' + ('' if args.token else ' Consider --token.'), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
