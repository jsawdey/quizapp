import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import build_trivia_db
from build_trivia_db import FetchError, build, fetch_all, parse_item, question_key, stable_shuffle

REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURES = REPO_ROOT / 'test' / 'support' / 'opentdb'
# Also checked by the app's tests (test/opentdb_dialect_test.dart).
VECTORS = REPO_ROOT / 'test' / 'support' / 'trivia_keys.json'


def fixture(name):
    return json.loads((FIXTURES / name).read_text(encoding='utf-8'))


def item(**changes):
    return {'type': 'multiple', 'difficulty': 'easy', 'category': 'C', 'question': 'Q%3F',
            'correct_answer': 'A', 'incorrect_answers': ['B', 'C', 'D'], **changes}


class KeyTest(unittest.TestCase):
    def test_keys_and_choice_order_match_the_app(self):
        for vector in json.loads(VECTORS.read_text(encoding='utf-8')):
            key = question_key(vector['category'], vector['question'], vector['answer'])
            self.assertEqual(key, vector['key'], vector['question'])
            if vector['type'] == 'multiple':
                self.assertEqual(
                    stable_shuffle(key, [vector['answer'], *vector['incorrect_answers']]),
                    vector['choices'])

    def test_parse_item_decodes_trims_and_keys(self):
        page = fixture('random.json')['results']
        water = parse_item(page[41])
        self.assertEqual(water['category'], 'Science & Nature')
        self.assertEqual(water['key'], '5fbea8159f0e84ea')
        # Sent as "Ammonia%20".
        self.assertEqual(water['choices'], ['Laughing Gas', 'Water', 'Methane', 'Ammonia'])
        self.assertEqual(parse_item(page[17])['choices'], ['Zürich', 'Wien', 'Bern', 'Frankfurt'])

    def test_parse_item_skips_what_the_app_skips(self):
        self.assertIsNotNone(parse_item(item()))
        for bad in [item(type='picture'), item(question='bad %zz encoding'),
                    item(question='%FF'), item(correct_answer='%20'),
                    item(incorrect_answers=['A', 'B', 'C']), item(incorrect_answers=['B', 3]),
                    item(type='boolean', correct_answer='Maybe', incorrect_answers=['False']),
                    'not an item']:
            self.assertIsNone(parse_item(bad), bad)


class BuildTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.output = Path(self.tmp.name) / 'trivia.db'

    def tearDown(self):
        self.tmp.cleanup()

    def build(self, items):
        return build(items, self.output, '2026-10-10T00:00:00+00:00', 'https://opentdb.com')

    def test_builds_from_saved_pages(self):
        items = fixture('random.json')['results'] + fixture('random_small_pool.json')['results']
        # The same question twice, and one the app would skip.
        items += [items[0], item(type='picture')]
        stats = self.build(items)
        self.assertEqual(stats['written'], 61)
        self.assertEqual(stats['duplicate'], 1)
        self.assertEqual(stats['skipped'], 1)

        conn = sqlite3.connect(self.output)
        ids = [row[0] for row in conn.execute('SELECT id FROM questions ORDER BY id')]
        self.assertEqual(ids, list(range(1, 62)))
        meta = dict(conn.execute('SELECT key, value FROM meta'))
        self.assertEqual(meta['schema_version'], '1')
        self.assertEqual(meta['dataset_kind'], 'trivia')
        self.assertEqual(meta['dataset_namespace'], 'opentdb')
        self.assertEqual(meta['license'], 'CC BY-SA 4.0')
        self.assertEqual(meta['question_count'], '61')
        row = conn.execute("SELECT category, difficulty, question, answer, choices "
                           "FROM questions WHERE key = '5fbea8159f0e84ea'").fetchone()
        self.assertEqual(row[:2], ('Science & Nature', 'easy'))
        self.assertEqual(row[3], 'Water')
        self.assertEqual(json.loads(row[4]), ['Laughing Gas', 'Water', 'Methane', 'Ammonia'])
        boolean = conn.execute("SELECT choices FROM questions WHERE key = '4af6d532be05b8a1'")
        self.assertEqual(json.loads(boolean.fetchone()[0]), ['True', 'False'])
        conn.close()

        version = json.loads(self.output.with_suffix('.version').read_text())
        self.assertEqual(version['question_count'], '61')

    def test_a_failed_build_leaves_no_partial_database(self):
        self.build([item()])
        before = self.output.read_bytes()
        with mock.patch.object(build_trivia_db, 'SCHEMA', 'CREATE TABLE broken ('):
            with self.assertRaises(sqlite3.Error):
                self.build([item(question='Another')])
        self.assertEqual(self.output.read_bytes(), before)
        self.assertEqual(list(Path(self.tmp.name).glob('*.db')), [self.output])


class FetchTest(unittest.TestCase):
    def fetch(self, responses):
        """Runs fetch_all against canned (status, body) responses for api.php."""
        self.urls, self.sleeps = [], []
        replies = iter(responses)

        def get_json(url):
            self.urls.append(url)
            if 'api_token.php' in url:
                return 200, fixture('token_request.json')
            return next(replies)

        return fetch_all('https://opentdb.com/', get_json=get_json,
                         sleep=self.sleeps.append, log=lambda _: None)

    def page(self, n):
        return 200, {'response_code': 0, 'results': [item(question=f'Q{i}') for i in range(n)]}

    def test_halves_the_batch_until_nothing_is_left(self):
        empty = (200, fixture('code4_token_empty.json'))
        results = self.fetch([self.page(50), self.page(50), empty, self.page(25), empty, empty,
                              self.page(6), empty, empty, empty])
        self.assertEqual(len(results), 131)
        amounts = [url.split('amount=')[1].split('&')[0] for url in self.urls[1:]]
        self.assertEqual(amounts, ['50', '50', '50', '25', '25', '12', '6', '6', '3', '1'])
        self.assertIn('token=0123456789abcdef', self.urls[1])
        self.assertEqual(self.sleeps, [build_trivia_db.REQUEST_GAP] * 10)

    def test_waits_out_the_rate_limit(self):
        limited = (429, fixture('code5_rate_limit.json'))
        empty = (200, fixture('code4_token_empty.json'))
        results = self.fetch([limited, self.page(3), empty] + [empty] * 5)
        self.assertEqual(len(results), 3)
        self.assertIn(build_trivia_db.RATE_LIMIT_PAUSE, self.sleeps)

        with self.assertRaises(FetchError):
            self.fetch([limited] * (build_trivia_db.MAX_RATE_LIMITED + 1))

    def test_unexpected_responses_stop_the_download(self):
        with self.assertRaises(FetchError):
            self.fetch([(200, fixture('code2_invalid_parameter.json'))])
        with self.assertRaises(FetchError):
            self.fetch([(500, None)])


if __name__ == '__main__':
    unittest.main()
