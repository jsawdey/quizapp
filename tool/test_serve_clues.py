"""Tests for serve_clues.py. Run with: python3 -m unittest discover tool"""

import json
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


class ServeCluesTest(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        write_tsv(self.dir / 'sample.tsv', SAMPLE_ROWS)
        self.db = self.dir / 'clues.db'
        build_clue_db.build(self.dir / 'sample.tsv', self.db, 'test', 'abc123')
        self.reports = self.dir / 'data' / 'reports.db'
        self.start()

    def start(self, token=None):
        self.store = serve_clues.ClueStore(self.db, self.reports, rng=random.Random(1))
        self.server = serve_clues.make_server(self.store, port=0, token=token, quiet=True)
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

    def responses(self, path='/v1/random?count=50'):
        status, body = self.request(path)
        self.assertEqual(status, 200)
        return {q['response'] for q in body['questions']}

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


if __name__ == '__main__':
    unittest.main()
