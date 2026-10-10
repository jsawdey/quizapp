"""Tests for serve_clues.py. Run with: python3 -m unittest discover tool"""

import email.utils
import http.client
import json
import os
import random
import sqlite3
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_clue_db  # noqa: E402
import serve_clues  # noqa: E402
from test_build_clue_db import SAMPLE_ROWS, write_tsv  # noqa: E402

# The sample TSV builds 6 clues; these are their responses.
ALL_RESPONSES = {'a hippopotamus', '"Thriller"', 'an elephant', 'St. Petersburg',
                 'four of a kind', 'a flush'}


class ServerTestCase(unittest.TestCase):
    """Starts serve_clues.py on a database built from the sample TSV."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        write_tsv(self.dir / 'sample.tsv', SAMPLE_ROWS)
        self.db = self.dir / 'clues.db'
        build_clue_db.build(self.dir / 'sample.tsv', self.db, 'test', 'abc123')
        self.reports = self.dir / 'data' / 'reports.db'
        self.web = self.make_web_build()
        self.start()

    def make_web_build(self):
        """Returns the directory to serve with --web, or None."""
        return None

    def start(self, token=None):
        self.store = serve_clues.ClueStore(self.db, self.reports, rng=random.Random(1))
        self.server = serve_clues.make_server(self.store, port=0, token=token, quiet=True,
                                              web_root=self.web)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = 'http://127.0.0.1:%d' % self.server.server_address[1]

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def tearDown(self):
        self.stop()
        self._tmp.cleanup()

    def request(self, path, method='GET', headers=None):
        """Returns (status, parsed JSON body or None)."""
        req = urllib.request.Request(self.base + path, method=method, headers=headers or {})
        try:
            with urllib.request.urlopen(req) as response:
                status, body = response.status, response.read()
        except urllib.error.HTTPError as e:
            status, body = e.code, e.read()
        return status, json.loads(body) if body else None

    def raw(self, path, method='GET', headers=None):
        """Returns (status, headers, body bytes), sending path exactly as given."""
        conn = http.client.HTTPConnection('127.0.0.1', self.server.server_address[1])
        try:
            conn.request(method, path, headers=headers or {})
            response = conn.getresponse()
            return response.status, response.headers, response.read()
        finally:
            conn.close()

    def responses(self, path='/v1/random?count=50'):
        status, body = self.request(path)
        self.assertEqual(status, 200)
        return {q['response'] for q in body['questions']}


class ServeCluesTest(ServerTestCase):

    def test_random_shape(self):
        status, body = self.request('/v1/random?count=2')
        self.assertEqual(status, 200)
        self.assertEqual(body['namespace'], 'jwolle1')
        self.assertEqual(len(body['questions']), 2)
        q = body['questions'][0]
        self.assertEqual(set(q), {'key', 'category', 'category_comment', 'clue', 'response',
                                  'value', 'round', 'dd_wager', 'air_date', 'notes'})
        self.assertIsInstance(q['key'], str)
        int(q['key'])

    def test_random_returns_distinct_clues_up_to_what_exists(self):
        status, body = self.request('/v1/random?count=50')
        keys = [q['key'] for q in body['questions']]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertEqual({q['response'] for q in body['questions']}, ALL_RESPONSES)

    def test_count_is_capped_and_defaulted(self):
        self.assertEqual(serve_clues.parse_random_query('count=500')[0], serve_clues.MAX_COUNT)
        self.assertEqual(serve_clues.parse_random_query('')[0], serve_clues.DEFAULT_COUNT)
        self.assertEqual(serve_clues.parse_random_query('count=3&unknown=1')[0], 3)

    def test_filters(self):
        self.assertEqual(self.responses('/v1/random?count=50&round=3'), {'St. Petersburg'})
        self.assertEqual(self.responses('/v1/random?count=50&round=1,3&from=2012-01-01'),
                         {'four of a kind', 'a flush'})
        self.assertEqual(self.responses('/v1/random?count=50&from=1984-09-11&to=1984-09-11'),
                         {'an elephant', 'St. Petersburg'})
        self.assertEqual(self.responses('/v1/random?count=50&from=2020-01-01'), set())

    def test_date_range_batches_are_full_and_fair(self):
        # 200 clues, ten on each of 20 dates. Before ids were limited to the
        # range, most picks landed on the range's first clue.
        rows = [['1', '200', '0', f'CATEGORY {d}', '', f'Clue {d}-{i}', f'response {d}-{i}',
                 f'{2000 + d}-03-01', ''] for d in range(20) for i in range(10)]
        write_tsv(self.dir / 'many.tsv', rows)
        build_clue_db.build(self.dir / 'many.tsv', self.db, 'test', 'abc123')
        store = serve_clues.ClueStore(self.db, self.reports, rng=random.Random(1))

        batch = store.random(10, date_from='2010-01-01', date_to='2011-12-31')
        self.assertEqual(len({q['key'] for q in batch}), 10)
        self.assertTrue(all(q['air_date'][:4] in ('2010', '2011') for q in batch))
        # Every clue in the range comes up.
        seen = {q['response'] for _ in range(20)
                for q in store.random(10, date_from='2010-01-01', date_to='2011-12-31')}
        self.assertEqual(seen, {f'response {d}-{i}' for d in (10, 11) for i in range(10)})
        self.assertEqual(store.random(10, date_from='2030-01-01'), [])
        self.assertEqual(store.random(10, date_from='2010-06-01', date_to='2010-12-31'), [])
        self.assertEqual(len(store.random(50, date_to='2000-12-31')), 10)

    def test_bad_parameters_are_400(self):
        for query in ['count=x', 'count=0', 'round=4', 'round=one', 'from=yesterday']:
            status, body = self.request('/v1/random?' + query)
            self.assertEqual(status, 400, query)
            self.assertIn('error', body)

    def test_report_hides_the_clue_and_persists(self):
        _, body = self.request('/v1/random?count=50&round=3')
        key = body['questions'][0]['key']
        status, body = self.request(f'/v1/questions/{key}/report', method='POST')
        self.assertEqual((status, body), (204, None))
        # Reporting twice is fine.
        self.assertEqual(self.request(f'/v1/questions/{key}/report', method='POST')[0], 204)
        self.assertEqual(self.responses('/v1/random?count=50&round=3'), set())
        self.assertEqual(self.responses(), ALL_RESPONSES - {'St. Petersburg'})

        # A restarted server still hides it.
        self.stop()
        self.start()
        self.assertEqual(self.responses(), ALL_RESPONSES - {'St. Petersburg'})
        conn = sqlite3.connect(self.reports)
        self.assertEqual(conn.execute('SELECT clue_key FROM reported').fetchall(), [(int(key),)])
        conn.close()

    def test_report_errors(self):
        self.assertEqual(self.request('/v1/questions/12345/report', method='POST')[0], 404)
        self.assertEqual(self.request('/v1/questions/abc/report', method='POST')[0], 400)
        self.assertEqual(self.request('/v1/questions/12345/report')[0], 405)

    def test_unknown_paths_and_methods(self):
        self.assertEqual(self.request('/v2/random')[0], 404)
        self.assertEqual(self.request('/')[0], 404)
        status, _ = self.request('/v1/random', method='POST')
        self.assertEqual(status, 405)

    def test_clue_database_is_not_modified(self):
        before = self.db.read_bytes()
        _, body = self.request('/v1/random?count=1')
        self.request(f'/v1/questions/{body["questions"][0]["key"]}/report', method='POST')
        self.assertEqual(self.db.read_bytes(), before)

    def test_token(self):
        self.stop()
        self.start(token='s3cret')
        self.assertEqual(self.request('/v1/random')[0], 401)
        self.assertEqual(self.request('/v1/random',
                                      headers={'Authorization': 'Bearer wrong'})[0], 401)
        self.assertEqual(self.request('/v1/random',
                                      headers={'Authorization': 'Bearer s3cret'})[0], 200)

    def test_rejects_other_schema_versions(self):
        conn = sqlite3.connect(self.db)
        conn.execute("UPDATE meta SET value = '2' WHERE key = 'schema_version'")
        conn.commit()
        conn.close()
        with self.assertRaises(ValueError):
            serve_clues.ClueStore(self.db, self.reports)

    def test_main_needs_a_database(self):
        self.assertEqual(serve_clues.main(['--db', str(self.dir / 'missing.db')]), 1)


class WebUiTest(ServerTestCase):
    """serve_clues.py --web: the Flutter web build next to the API."""

    def make_web_build(self):
        web = self.dir / 'web'
        (web / 'canvaskit').mkdir(parents=True)
        (web / 'index.html').write_text('<html>quiz</html>')
        (web / 'main.dart.js').write_text('main();')
        (web / 'canvaskit' / 'canvaskit.wasm').write_bytes(b'\0asm')
        (web / 'font.otf').write_bytes(b'OTTO')
        (web / '.env').write_text('hidden')
        (self.dir / 'secret.txt').write_text('outside the web root')
        os.symlink(self.dir / 'secret.txt', web / 'link.txt')
        return web

    def test_serves_index_at_root(self):
        status, headers, body = self.raw('/')
        self.assertEqual((status, body), (200, b'<html>quiz</html>'))
        self.assertEqual(headers['Content-Type'], 'text/html; charset=utf-8')
        self.assertEqual(headers['Cache-Control'], 'no-cache')
        self.assertEqual(self.raw('/index.html')[2], b'<html>quiz</html>')

    def test_content_types(self):
        for path, content_type in [('/main.dart.js', 'text/javascript; charset=utf-8'),
                                   ('/canvaskit/canvaskit.wasm', 'application/wasm'),
                                   ('/font.otf', 'font/otf')]:
            status, headers, _ = self.raw(path)
            self.assertEqual(status, 200, path)
            self.assertEqual(headers['Content-Type'], content_type, path)

    def test_head_has_no_body(self):
        status, headers, body = self.raw('/main.dart.js', method='HEAD')
        self.assertEqual((status, body), (200, b''))
        self.assertEqual(headers['Content-Length'], '7')

    def test_refuses_paths_outside_the_build(self):
        for path in ['/../secret.txt', '/canvaskit/../../secret.txt', '/%2e%2e/secret.txt',
                     '/..%2fsecret.txt', '/.env', '/link.txt', '/canvaskit', '/canvaskit/',
                     '/missing.js', '/a%00b', '/..%5csecret.txt']:
            status, _, body = self.raw(path)
            self.assertEqual(status, 404, path)
            self.assertNotIn(b'outside', body, path)

    def test_only_get_and_head(self):
        self.assertEqual(self.raw('/', method='POST')[0], 405)

    def test_not_modified(self):
        _, headers, _ = self.raw('/main.dart.js')
        last_modified = headers['Last-Modified']
        status, _, body = self.raw('/main.dart.js', headers={'If-Modified-Since': last_modified})
        self.assertEqual((status, body), (304, b''))
        os.utime(self.web / 'main.dart.js', (2_000_000_000, 2_000_000_000))
        self.assertEqual(self.raw('/main.dart.js',
                                  headers={'If-Modified-Since': last_modified})[0], 200)
        self.assertEqual(self.raw('/main.dart.js',
                                  headers={'If-Modified-Since': 'yesterday'})[0], 200)

    def test_api_still_works(self):
        self.assertEqual(self.responses(), ALL_RESPONSES)
        self.assertEqual(self.request('/v1/nothing')[0], 404)
        self.assertEqual(self.request('/v1/random', method='POST')[0], 405)
        # Outside /v1/ is the web build's, so this is a missing file.
        self.assertEqual(self.raw('/v2/random')[0], 404)

    def test_token_guards_only_the_api(self):
        self.stop()
        self.start(token='s3cret')
        self.assertEqual(self.raw('/')[0], 200)
        self.assertEqual(self.raw('/main.dart.js')[0], 200)
        self.assertEqual(self.request('/v1/random')[0], 401)
        self.assertEqual(self.request('/v1/nothing')[0], 401)
        self.assertEqual(self.request('/v1/random',
                                      headers={'Authorization': 'Bearer s3cret'})[0], 200)

    def test_main_needs_a_web_build(self):
        (self.web / 'index.html').unlink()
        self.assertEqual(serve_clues.main(['--db', str(self.db), '--web', str(self.web)]), 1)

    def test_detects_builds_that_use_the_cdn(self):
        self.assertFalse(serve_clues.web_build_uses_cdn(self.web))  # No bootstrap file.
        bootstrap = self.web / 'flutter_bootstrap.js'
        bootstrap.write_text('_flutter.buildConfig = {"engineRevision":"abc","builds":[]};')
        self.assertTrue(serve_clues.web_build_uses_cdn(self.web))
        bootstrap.write_text('_flutter.buildConfig = {"engineRevision":"abc",'
                             '"useLocalCanvasKit":true,"builds":[]};')
        self.assertFalse(serve_clues.web_build_uses_cdn(self.web))

    def test_formats_last_modified_as_http_date(self):
        _, headers, _ = self.raw('/')
        self.assertIsNotNone(email.utils.parsedate_to_datetime(headers['Last-Modified']))


if __name__ == '__main__':
    unittest.main()
