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
        self.history = serve_clues.HistoryStore(self.dir / 'data' / 'history.db')
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
                                              web_root=self.web, history=self.history)
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

    def request(self, path, method='GET', headers=None, body=None):
        """Returns (status, parsed JSON body or None). A body other than bytes is
        sent as JSON."""
        if body is not None and not isinstance(body, bytes):
            body = json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, method=method, headers=headers or {},
                                     data=body)
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


def answer(n, **fields):
    """An answer for POST /v1/history, the nth of game 1."""
    return {'id': f'{n:032x}', 'game': '1' * 32, 'answered_at': f'2026-10-13T18:{n % 60:02d}:00Z',
            'utc_offset': -240, 'namespace': 'jwolle1', 'key': str(1000 + n),
            'category': 'BIOGRAPHIES', 'format': 'open', 'round': 1, 'row': 2, 'value': 400,
            'daily_double': False, 'difficulty': None, 'right': True, **fields}


def game(**fields):
    return {'id': '1' * 32, 'started': '2026-10-13', 'updated_at': '2026-10-13T18:35:10.123Z',
            'answered': 10, 'right': 7, 'best': 4, 'dollars': 4200, 'valued': 8, **fields}


class HistoryTest(ServerTestCase):

    def send(self, answers=(), games=(), headers=None):
        return self.request('/v1/history', method='POST', headers=headers,
                            body={'answers': list(answers), 'games': list(games)})[0]

    def fetch(self, after=0, limit=None):
        query = f'?after={after}' + (f'&limit={limit}' if limit else '')
        status, body = self.request('/v1/history' + query)
        self.assertEqual(status, 200)
        return body

    def test_info_says_history(self):
        self.assertTrue(self.request('/v1/info')[1]['history'])

    def test_upload_and_fetch(self):
        self.assertEqual(self.send([answer(1), answer(2, right=False)], [game()]), 204)
        body = self.fetch()
        self.assertEqual(body['history'], self.history.history_id)
        self.assertEqual([a['id'] for a in body['answers']], [f'{1:032x}', f'{2:032x}'])
        self.assertEqual(body['answers'][0], {**answer(1), 'answered_at': '2026-10-13T18:01:00.000Z'})
        self.assertIs(body['answers'][1]['right'], False)
        self.assertEqual(body['games'], [game()])
        self.assertEqual(body['next'], 3)
        self.assertFalse(body['more'])
        self.assertEqual(self.fetch(after=3), {'history': self.history.history_id, 'answers': [],
                                               'games': [], 'next': 3, 'more': False})

    def test_times_are_kept_in_one_form(self):
        self.send([answer(1, answered_at='2026-10-13T18:35:10.123456Z'),
                   answer(2, answered_at='2026-10-13T18:35:10.5Z')])
        self.assertEqual([a['answered_at'] for a in self.fetch()['answers']],
                         ['2026-10-13T18:35:10.123Z', '2026-10-13T18:35:10.500Z'])

    def test_a_change_of_mind_replaces_the_answer(self):
        self.send([answer(1)])
        self.send([answer(1, right=False)])
        body = self.fetch()
        self.assertEqual(len(body['answers']), 1)
        self.assertIs(body['answers'][0]['right'], False)
        self.assertEqual(body['next'], 2)
        self.assertEqual([a['right'] for a in self.fetch(after=1)['answers']], [False])

    def test_sending_again_changes_nothing(self):
        self.send([answer(1)], [game()])
        self.send([answer(1)], [game()])
        self.assertEqual(self.fetch()['next'], 2)

    def test_an_older_game_row_does_not_replace_a_newer_one(self):
        self.send(games=[game(answered=11, right=8, updated_at='2026-10-13T18:40:00Z')])
        self.send(games=[game()])
        self.assertEqual(self.fetch()['games'][0]['answered'], 11)
        self.send(games=[game(answered=12, right=9, updated_at='2026-10-13T18:41:00Z')])
        self.assertEqual(self.fetch()['games'][0]['answered'], 12)

    def test_pages(self):
        self.send([answer(n) for n in range(1, 6)], [game()])
        first = self.fetch(limit=4)
        self.assertEqual((len(first['answers']), first['next'], first['more']), (4, 4, True))
        second = self.fetch(after=first['next'], limit=4)
        self.assertEqual((len(second['answers']), len(second['games'])), (1, 1))
        self.assertEqual((second['next'], second['more']), (6, False))

    def test_history_survives_a_restart(self):
        self.send([answer(1)])
        history_id = self.history.history_id
        self.stop()
        self.history = serve_clues.HistoryStore(self.dir / 'data' / 'history.db')
        self.start()
        self.assertEqual(self.history.history_id, history_id)
        self.assertEqual(len(self.fetch()['answers']), 1)

    def test_a_new_database_has_a_new_history_id(self):
        other = serve_clues.HistoryStore(self.dir / 'other.db')
        self.assertNotEqual(other.history_id, self.history.history_id)

    def test_bad_uploads_are_400_and_store_nothing(self):
        bad = [
            ({'answers': [answer(1, id='nope')]}, 'answers[0].id'),
            ({'answers': [answer(1), answer(2, format='essay')]}, 'answers[1].format'),
            ({'answers': [answer(1, round=4)]}, 'answers[0].round'),
            ({'answers': [answer(1, row=0)]}, 'answers[0].row'),
            ({'answers': [answer(1, right=1)]}, 'answers[0].right'),
            ({'answers': [answer(1, answered_at='2026-10-13 18:00')]}, 'answers[0].answered_at'),
            ({'answers': [answer(1, answered_at='2026-02-30T18:00:00Z')]}, 'answers[0].answered_at'),
            ({'answers': [answer(1, utc_offset=10000)]}, 'answers[0].utc_offset'),
            ({'answers': [answer(1, key='')]}, 'answers[0].key'),
            ({'answers': [{k: v for k, v in answer(1).items() if k != 'game'}]}, 'answers[0].game'),
            ({'games': [game(right=11)]}, 'games[0]'),
            ({'games': [game(started='13/10/2026')]}, 'games[0].started'),
            ({'answers': 'x'}, 'lists'),
            ([], 'object'),
        ]
        for body, problem in bad:
            with self.subTest(problem=problem):
                status, error = self.request('/v1/history', method='POST', body=body)
                self.assertEqual(status, 400)
                self.assertIn(problem, error['error'])
        status, _ = self.request('/v1/history', method='POST', body=b'{not json')
        self.assertEqual(status, 400)
        self.assertEqual(self.fetch()['next'], 0)

    def test_too_much_at_once_is_413(self):
        self.assertEqual(self.send([answer(n) for n in range(501)]), 413)
        # Refused from the headers alone: the body is never read.
        conn = http.client.HTTPConnection('127.0.0.1', self.server.server_address[1])
        try:
            conn.putrequest('POST', '/v1/history')
            conn.putheader('Content-Length', str(serve_clues.MAX_HISTORY_BODY + 1))
            conn.endheaders()
            self.assertEqual(conn.getresponse().status, 413)
        finally:
            conn.close()

    def test_bad_queries_are_400(self):
        for query in ('?after=x', '?after=-1', '?limit=0', '?limit=1001'):
            with self.subTest(query=query):
                self.assertEqual(self.request('/v1/history' + query)[0], 400)

    def test_other_methods(self):
        self.assertEqual(self.raw('/v1/history', method='HEAD')[0], 405)

    def test_token_guards_history(self):
        self.stop()
        self.start(token='s3cret')
        self.assertEqual(self.send([answer(1)]), 401)
        self.assertEqual(self.request('/v1/history')[0], 401)
        auth = {'Authorization': 'Bearer s3cret'}
        self.assertEqual(self.send([answer(1)], headers=auth), 204)
        self.assertEqual(self.request('/v1/history', headers=auth)[0], 200)

    def test_main_says_when_history_cannot_be_kept(self):
        history = self.dir / 'clues.db' / 'history.db'
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = serve_clues.main(['--db', str(self.db), '--reports', str(self.reports),
                                     '--history', str(history)])
        self.assertEqual(code, 1)
        self.assertIn(f'cannot keep the score history in {history.resolve()}',
                      stderr.getvalue())

    def test_servers_without_history_say_nothing(self):
        self.stop()
        self.history = None
        self.start()
        self.assertNotIn('history', self.request('/v1/info')[1])
        self.assertEqual(self.request('/v1/history')[0], 404)


class ServerSettingsTest(unittest.TestCase):

    def parse(self, argv, **environ):
        with unittest.mock.patch.dict(os.environ, environ):
            for name in ('QUIZ_DB', 'QUIZ_TOKEN'):
                if name not in environ:
                    os.environ.pop(name, None)
            return serve_clues.parse_args(argv)

    def test_defaults(self):
        args = self.parse([])
        self.assertEqual(args.db, serve_clues.DEFAULT_DB)
        self.assertIsNone(args.token)

    def test_environment_stands_in_for_flags(self):
        args = self.parse([], QUIZ_DB='/data/trivia.db', QUIZ_TOKEN='s3cret')
        self.assertEqual(args.db, Path('/data/trivia.db'))
        self.assertEqual(args.token, 's3cret')

    def test_flags_win(self):
        args = self.parse(['--db', 'other.db', '--token', 'flag'],
                          QUIZ_DB='/data/trivia.db', QUIZ_TOKEN='s3cret')
        self.assertEqual(args.db, Path('other.db'))
        self.assertEqual(args.token, 'flag')

    def test_empty_values_are_unset(self):
        args = self.parse([], QUIZ_DB='', QUIZ_TOKEN='')
        self.assertEqual(args.db, serve_clues.DEFAULT_DB)
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
                 '--reports', str(tmp / 'reports.db'), '--history', str(tmp / 'history.db'),
                 '--port', '0', '--quiet'],
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
