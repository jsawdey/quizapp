"""Tests for serve_clues.py. Run with: python3 -m unittest discover tool"""

import contextlib
import email.utils
import http.client
import io
import json
import os
import random
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
import unittest.mock
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_clue_db  # noqa: E402
import build_trivia_db  # noqa: E402
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
        self.db = self.make_db()
        self.reports = self.dir / 'data' / 'reports.db'
        self.web = self.make_web_build()
        self.start()

    def make_db(self):
        """Builds the database to serve and returns its path."""
        write_tsv(self.dir / 'sample.tsv', SAMPLE_ROWS)
        db = self.dir / 'clues.db'
        build_clue_db.build(self.dir / 'sample.tsv', db, 'test', 'abc123')
        return db

    def make_web_build(self):
        """Returns the directory to serve with --web, or None."""
        return None

    def start(self, token=None):
        self.store = serve_clues.open_store(self.db, self.reports, rng=random.Random(1))
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

    def test_board_rows_match_the_shared_examples(self):
        # The same examples check the app's Question.boardRow and
        # LocalQuestionSource. Final Jeopardy has no row and always passes.
        examples = json.loads((Path(__file__).resolve().parent.parent / 'test' / 'support'
                               / 'board_rows.json').read_text(encoding='utf-8'))
        rows = [[str(e['round']), str(e['value']), '0', 'CATEGORY', '', f'Clue {i}',
                 f'response {i}', e['air_date'], ''] for i, e in enumerate(examples)]
        write_tsv(self.dir / 'rows.tsv', rows)
        build_clue_db.build(self.dir / 'rows.tsv', self.db, 'test', 'abc123')
        store = serve_clues.ClueStore(self.db, self.reports, rng=random.Random(1))
        for row in range(1, 6):
            found = {q['response'] for _ in range(20) for q in store.random(50, rows={row})}
            expected = {f'response {i}' for i, e in enumerate(examples)
                        if e['row'] == row or e['round'] == 3}
            self.assertEqual(found, expected, f'row {row}')
        self.assertEqual(serve_clues.parse_random_query('row=5,4')[4], {4, 5})
        self.assertIsNone(serve_clues.parse_random_query('')[4])

    def test_bad_parameters_are_400(self):
        for query in ['count=x', 'count=0', 'round=4', 'round=one', 'from=yesterday',
                      'row=6', 'row=0', 'row=top']:
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

    def test_main_says_when_reports_cannot_be_kept(self):
        # A folder that can't be created, even by root: its parent is a file.
        reports = self.dir / 'clues.db' / 'reports.db'
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = serve_clues.main(['--db', str(self.db), '--reports', str(reports)])
        self.assertEqual(code, 1)
        self.assertIn(f'cannot keep reported questions in {reports.resolve()}',
                      stderr.getvalue())


class ServerSettingsTest(unittest.TestCase):

    def parse(self, argv, **environ):
        with unittest.mock.patch.dict(os.environ, environ):
            for name in ('QUIZ_DB', 'QUIZ_TOKEN'):
                if name not in environ:
                    os.environ.pop(name, None)
            return serve_clues.parse_args(argv)

    def test_defaults(self):
        args = self.parse([])
        self.assertEqual(args.db, [serve_clues.DEFAULT_DB])
        self.assertIsNone(args.token)

    def test_environment_stands_in_for_flags(self):
        args = self.parse([], QUIZ_DB='/data/trivia.db', QUIZ_TOKEN='s3cret')
        self.assertEqual(args.db, [Path('/data/trivia.db')])
        self.assertEqual(args.token, 's3cret')

    def test_environment_lists_databases_with_commas(self):
        args = self.parse([], QUIZ_DB=' /data/clues.db , /data/trivia.db,')
        self.assertEqual(args.db, [Path('/data/clues.db'), Path('/data/trivia.db')])

    def test_flags_win(self):
        args = self.parse(['--db', 'other.db', '--token', 'flag'],
                          QUIZ_DB='/data/clues.db,/data/trivia.db', QUIZ_TOKEN='s3cret')
        self.assertEqual(args.db, [Path('other.db')])
        self.assertEqual(args.token, 'flag')

    def test_db_can_be_given_more_than_once(self):
        args = self.parse(['--db', 'clues.db', '--db', 'trivia.db'])
        self.assertEqual(args.db, [Path('clues.db'), Path('trivia.db')])

    def test_empty_values_are_unset(self):
        args = self.parse([], QUIZ_DB='', QUIZ_TOKEN='')
        self.assertEqual(args.db, [serve_clues.DEFAULT_DB])
        self.assertIsNone(args.token)


class ServerProcessTest(unittest.TestCase):

    def test_stops_cleanly_on_sigterm(self):
        # docker stop sends SIGTERM. Without a handler the process would end
        # with -SIGTERM here, and be ignored altogether as a container's
        # first process.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            write_tsv(tmp / 'sample.tsv', SAMPLE_ROWS)
            build_clue_db.build(tmp / 'sample.tsv', tmp / 'clues.db', 'test', 'abc123')
            env = {k: v for k, v in os.environ.items() if not k.startswith('QUIZ_')}
            server = subprocess.Popen(
                [sys.executable, str(Path(serve_clues.__file__)), '--db', str(tmp / 'clues.db'),
                 '--reports', str(tmp / 'reports.db'), '--port', '0', '--quiet'],
                stdout=subprocess.PIPE, text=True, env=env)
            try:
                self.assertIn('Serving 6 clues', server.stdout.readline())
                server.send_signal(signal.SIGTERM)
                self.assertEqual(server.wait(timeout=10), 0)
            finally:
                server.kill()
                server.wait()
                server.stdout.close()


class ServeTriviaTest(ServerTestCase):
    """Serves a trivia database built from the saved OpenTDB responses."""

    FIXTURES = Path(__file__).resolve().parent.parent / 'test' / 'support' / 'opentdb'

    def make_db(self):
        items = []
        for name in ('random.json', 'random_small_pool.json'):
            items += json.loads((self.FIXTURES / name).read_text(encoding='utf-8'))['results']
        db = self.dir / 'trivia.db'
        build_trivia_db.build(items, db, '2026-10-10T00:00:00+00:00', 'https://opentdb.com')
        return db

    def test_info(self):
        status, info = self.request('/v1/info')
        self.assertEqual(status, 200)
        self.assertEqual(info['kind'], 'trivia')
        self.assertEqual(info['namespace'], 'opentdb')
        self.assertEqual(info['filters'], ['category', 'difficulty'])
        self.assertEqual(info['count'], 61)
        self.assertIn('Entertainment: Musicals & Theatres', info['categories'])
        self.assertEqual(info['categories'], sorted(info['categories']))
        self.assertEqual(info['license'], 'CC BY-SA 4.0')
        self.assertIn('Open Trivia Database', info['attribution'])

    def test_random_shape(self):
        status, body = self.request('/v1/random?count=50')
        self.assertEqual(status, 200)
        self.assertEqual(body['namespace'], 'opentdb')
        questions = body['questions']
        self.assertEqual(len(questions), 50)
        self.assertEqual(len({q['key'] for q in questions}), 50)
        q = questions[0]
        self.assertEqual(set(q), {'key', 'category', 'clue', 'response', 'choices', 'difficulty'})
        self.assertIn(q['response'], q['choices'])

    def test_filters(self):
        musicals = 'category=Entertainment%3A%20Musicals%20%26%20Theatres'
        status, body = self.request(f'/v1/random?count=50&{musicals}&difficulty=hard')
        self.assertEqual(status, 200)
        self.assertEqual(len(body['questions']), 11)
        self.assertEqual({(q['category'], q['difficulty']) for q in body['questions']},
                         {('Entertainment: Musicals & Theatres', 'hard')})
        # Two categories, one of them repeated.
        _, body = self.request(f'/v1/random?count=50&{musicals}&category=Geography'
                               f'&category=Geography&difficulty=easy,medium')
        self.assertTrue(body['questions'])
        self.assertTrue({q['category'] for q in body['questions']} <= {'Geography'})
        self.assertEqual(self.request('/v1/random?category=Knitting')[1]['questions'], [])
        self.assertEqual(self.request('/v1/random?difficulty=impossible')[0], 400)

    def test_every_matching_question_turns_up(self):
        musicals = 'category=Entertainment%3A%20Musicals%20%26%20Theatres&difficulty=hard'
        seen = {q['key'] for _ in range(100)
                for q in self.request(f'/v1/random?count=1&{musicals}')[1]['questions']}
        self.assertEqual(len(seen), 11)

    def test_report_hides_the_question_and_persists(self):
        _, body = self.request('/v1/random?count=1')
        key = body['questions'][0]['key']
        self.assertEqual(self.request(f'/v1/questions/{key}/report', method='POST')[0], 204)
        self.assertEqual(self.request('/v1/questions/nope/report', method='POST')[0], 404)
        for _ in range(5):
            keys = {q['key'] for q in self.request('/v1/random?count=50')[1]['questions']}
            self.assertNotIn(key, keys)
            self.assertEqual(len(keys), 50)
        self.stop()
        self.start()
        _, body = self.request('/v1/random?count=50')
        self.assertNotIn(key, {q['key'] for q in body['questions']})

    def test_clue_servers_describe_themselves_too(self):
        clues = ServeCluesTest.make_db(self)
        store = serve_clues.open_store(clues, self.reports)
        self.assertEqual(store.info(), {'namespace': 'jwolle1', 'kind': 'clues',
                                        'filters': ['round', 'air_date', 'row'], 'count': 6})
        self.assertIsNone(store.license)
        self.assertEqual(self.store.license, 'CC BY-SA 4.0')


class SeveralDatabasesTest(ServerTestCase):
    """Clues and trivia from one server (docs/combined-server-plan.md)."""

    FIXTURES = ServeTriviaTest.FIXTURES

    def make_db(self):
        self.trivia = ServeTriviaTest.make_db(self)
        return ServeCluesTest.make_db(self)

    def start(self, token=None):
        self.stores = serve_clues.open_stores([self.db, self.trivia], self.reports,
                                              rng=random.Random(1))
        self.server = serve_clues.make_server(self.stores, port=0, token=token, quiet=True,
                                              web_root=self.web)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = 'http://127.0.0.1:%d' % self.server.server_address[1]

    def test_the_first_is_the_default_and_each_has_its_name(self):
        self.assertEqual(list(self.stores), ['clues', 'trivia'])
        self.assertEqual(self.responses(), ALL_RESPONSES)
        self.assertEqual(self.responses('/clues/v1/random?count=50'), ALL_RESPONSES)
        status, body = self.request('/trivia/v1/random?count=50')
        self.assertEqual(status, 200)
        self.assertEqual(body['namespace'], 'opentdb')
        self.assertEqual(len(body['questions']), 50)
        self.assertEqual(self.request('/trivia/v1/info')[1]['kind'], 'trivia')
        # Each database's own parameters.
        self.assertEqual(self.request('/trivia/v1/random?difficulty=impossible')[0], 400)
        self.assertEqual(self.request('/v1/random?round=4')[0], 400)

    def test_info_lists_the_databases_relative_to_the_base(self):
        _, info = self.request('/v1/info')
        self.assertEqual(info['kind'], 'clues')
        self.assertEqual(info['datasets'], [
            {'name': 'clues', 'kind': 'clues', 'count': 6, 'path': './'},
            {'name': 'trivia', 'kind': 'trivia', 'count': 61, 'path': 'trivia/'},
        ])
        _, info = self.request('/trivia/v1/info')
        self.assertEqual([d['path'] for d in info['datasets']], ['../', './'])
        # The default is always the root, never clues/.
        _, info = self.request('/clues/v1/info')
        self.assertEqual([d['path'] for d in info['datasets']], ['../', '../trivia/'])

    def test_one_database_lists_itself(self):
        clues = serve_clues.open_stores([self.db], self.reports)['clues']
        handler = serve_clues.datasets({'clues': clues}, None)
        self.assertEqual(handler, [{'name': 'clues', 'kind': 'clues', 'count': 6, 'path': './'}])

    def test_reports_through_either_path_share_one_file(self):
        _, body = self.request('/trivia/v1/random?count=1')
        trivia_key = body['questions'][0]['key']
        _, body = self.request('/v1/random?count=1')
        clue_key = body['questions'][0]['key']
        self.assertEqual(self.request(f'/trivia/v1/questions/{trivia_key}/report',
                                      method='POST')[0], 204)
        self.assertEqual(self.request(f'/v1/questions/{clue_key}/report', method='POST')[0], 204)
        # A key is only found in its own database.
        self.assertEqual(self.request(f'/v1/questions/{trivia_key}/report', method='POST')[0], 400)
        self.assertEqual(self.request(f'/trivia/v1/questions/{clue_key}/report',
                                      method='POST')[0], 404)
        self.stop()
        self.start()
        self.assertNotIn(trivia_key, {q['key'] for q in
                                      self.request('/trivia/v1/random?count=50')[1]['questions']})
        self.assertNotIn(clue_key, {q['key'] for q in
                                    self.request('/v1/random?count=50')[1]['questions']})
        with contextlib.closing(sqlite3.connect(self.reports)) as conn:
            tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master")}
        self.assertTrue({'reported', 'reported_trivia'} <= tables)

    def test_token_guards_every_database(self):
        self.stop()
        self.start(token='s3cret')
        for path in ('/v1/info', '/trivia/v1/info', '/clues/v1/random'):
            self.assertEqual(self.request(path)[0], 401, path)
            self.assertEqual(self.request(path, headers={'Authorization': 'Bearer s3cret'})[0],
                             200, path)

    def test_other_paths_are_not_the_api(self):
        self.assertEqual(self.request('/trivia/random')[0], 404)
        self.assertEqual(self.request('/quiz/v1/info')[0], 404)
        self.assertEqual(self.request('/trivia/v2/info')[0], 404)

    def test_names_must_be_path_segments_when_there_are_several(self):
        for name in ('My Trivia.db', 'v1.db', 'Trivia.db'):
            path = self.dir / name
            path.write_bytes(self.trivia.read_bytes())
            with self.assertRaisesRegex(ValueError, 'Rename it'):
                serve_clues.open_stores([self.db, path], self.reports)
            # One database is only served at /v1/, so its name doesn't matter.
            self.assertEqual(len(serve_clues.open_stores([path], self.reports)), 1)
        other = self.dir / 'other'
        other.mkdir()
        (other / 'clues.db').write_bytes(self.db.read_bytes())
        with self.assertRaisesRegex(ValueError, 'more than one database is called clues.db'):
            serve_clues.open_stores([self.db, other / 'clues.db'], self.reports)

    def test_main_names_every_database(self):
        # main() handles SIGTERM; keep that out of the test run.
        self.addCleanup(signal.signal, signal.SIGTERM, signal.getsignal(signal.SIGTERM))
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), \
                unittest.mock.patch.object(serve_clues.ThreadingHTTPServer, 'serve_forever',
                                           side_effect=KeyboardInterrupt):
            code = serve_clues.main(['--db', str(self.db), '--db', str(self.trivia),
                                     '--reports', str(self.reports), '--port', '0',
                                     '--host', '0.0.0.0'])
        self.assertEqual(code, 0)
        lines = stdout.getvalue().splitlines()
        self.assertRegex(lines[0], r'^Serving 6 clues on http://0\.0\.0\.0:\d+/v1/random '
                                   r'\(also /clues/v1/random\)$')
        self.assertRegex(lines[1], r'^Serving 61 trivia questions on '
                                   r'http://0\.0\.0\.0:\d+/trivia/v1/random$')
        # The clues have no open licence, so the notice shows.
        self.assertIn('Personal use only', stdout.getvalue())

    def test_main_says_which_database_it_cannot_read(self):
        stderr = io.StringIO()
        trivia = str(self.trivia)
        readable = os.access
        with contextlib.redirect_stderr(stderr), unittest.mock.patch.object(
                serve_clues.os, 'access', side_effect=lambda path, mode: (
                    str(path) != trivia and readable(path, mode))):
            code = serve_clues.main(['--db', str(self.db), '--db', trivia,
                                     '--reports', str(self.reports)])
        self.assertEqual(code, 1)
        self.assertIn(f'cannot read {trivia}: permission denied. It belongs to user '
                      f'{self.trivia.stat().st_uid}, and this server runs as user '
                      f'{os.getuid()}.', stderr.getvalue())
        self.assertIn('chmod a+r', stderr.getvalue())

    def test_main_says_when_paths_are_joined_with_colons(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = serve_clues.main(['--db', f'{self.db}:{self.trivia}'])
        self.assertEqual(code, 1)
        self.assertIn('separate them with commas, not colons', stderr.getvalue())

    def test_a_database_that_cannot_be_opened_is_named(self):
        broken = self.dir / 'broken.db'
        broken.write_text('not a database')
        with self.assertRaisesRegex(ValueError, f'cannot open {broken}: '):
            serve_clues.open_stores([self.db, broken], self.reports)

    def test_main_needs_every_database(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = serve_clues.main(['--db', str(self.db), '--db', str(self.dir / 'missing.db')])
        self.assertEqual(code, 1)
        self.assertIn('missing.db does not exist', stderr.getvalue())


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

    def test_a_database_name_only_claims_its_api(self):
        status, headers, _ = self.raw('/clues/v1/info')
        self.assertEqual((status, headers['Content-Type']),
                         (200, 'application/json; charset=utf-8'))
        status, headers, _ = self.raw('/clues/index.html')
        self.assertEqual((status, headers['Content-Type']), (404, 'text/plain; charset=utf-8'))

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
