"""Tests for build_clue_db.py. Run with: python3 -m unittest discover tool"""

import hashlib
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_clue_db  # noqa: E402

HEADER = '\t'.join(build_clue_db.EXPECTED_COLUMNS)

SAMPLE_ROWS = [
    # round, clue_value, daily_double_value, category, comments, answer, question, air_date, notes
    ['1', '400', '0', 'ANIMALS', '',
     'Close relative of the pig, though its name means "river horse\\"', 'a hippopotamus',
     '1984-09-10', ''],
    ['1', '100', '0', 'ACTORS & ROLES', '',
     'Video in which Michael Jackson plays a werewolf & a zombie', '\\"Thriller\\"',
     '1984-09-10', ''],
    ['2', '800', '1500', 'ANIMALS', '(Alex: Each one is a mammal.\\',
     "It\\'s the largest living land animal", 'an elephant', '1984-09-11', ''],
    ['3', '0', '0', 'WORLD CAPITALS', '', 'It was founded by Peter the Great', 'St. Petersburg',
     '1984-09-11', 'Tournament of Champions game 1.'],
    # Same date, round, category and text as the next row, but a different value: both kept.
    ['1', '600', '0', "TEXAS HOLD 'EM", '', 'Name this hand', 'four of a kind', '2012-09-17', ''],
    ['1', '800', '0', "TEXAS HOLD 'EM", '', 'Name this hand', 'a flush', '2012-09-17', ''],
    # An exact duplicate of the row above: dropped.
    ['1', '800', '0', "TEXAS HOLD 'EM", '', 'Name this hand', 'a flush', '2012-09-17', ''],
    # Empty response: dropped.
    ['1', '200', '0', 'ANIMALS', '', 'A clue with no response', '', '1984-09-10', ''],
    # Needs a video clip: dropped.
    ['1', '400', '0', 'GONE FISHING', '', "It's the skill being demonstrated here", 'casting',
     '1984-09-10', ''],
]


def write_tsv(path, rows, header=HEADER):
    path.write_text(header + '\n' + ''.join('\t'.join(r) + '\n' for r in rows),
                    encoding='utf-8')


class BuildClueDbTest(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.tsv = self.dir / 'sample.tsv'
        self.db = self.dir / 'out' / 'clues.db'
        write_tsv(self.tsv, SAMPLE_ROWS)

    def tearDown(self):
        self._tmp.cleanup()

    def build(self):
        return build_clue_db.build(self.tsv, self.db, 'test', 'abc123')

    def query(self, sql, *params):
        conn = sqlite3.connect(self.db)
        try:
            return conn.execute(sql, params).fetchall()
        finally:
            conn.close()

    def test_counts(self):
        stats = self.build()
        self.assertEqual(stats['read'], 9)
        self.assertEqual(stats['written'], 6)
        self.assertEqual(stats['dropped_empty'], 1)
        self.assertEqual(stats['dropped_duplicate'], 1)
        self.assertEqual(stats['dropped_media'], {'shown_here': 1})
        self.assertEqual(stats['rounds'], {1: 4, 2: 1, 3: 1})
        self.assertEqual(stats['games'], 3)
        self.assertEqual(stats['categories'], 4)
        self.assertEqual(self.query('SELECT COUNT(*) FROM clues'), [(6,)])

    def test_keep_media(self):
        stats = build_clue_db.build(self.tsv, self.db, 'test', 'abc123', keep_media=True)
        self.assertEqual(stats['written'], 7)
        self.assertEqual(stats['dropped_media'], {})

    def test_ids_are_contiguous(self):
        self.build()
        self.assertEqual([r[0] for r in self.query('SELECT id FROM clues ORDER BY id')],
                         [1, 2, 3, 4, 5, 6])

    def test_ids_follow_air_date(self):
        # Rows out of date order are numbered by date; rows on one date keep
        # their file order. Game ids follow the same order.
        late = [['1', '200', '0', 'LATE', '', f'Late clue {i}', f'late {i}', '2020-01-0' + str(i),
                 ''] for i in (2, 1)]
        write_tsv(self.tsv, late + SAMPLE_ROWS)
        self.build()
        rows = self.query('SELECT c.id, g.id, g.air_date, c.response FROM clues c '
                          'JOIN games g ON g.id = c.game_id ORDER BY c.id')
        self.assertEqual([r[2] for r in rows], sorted(r[2] for r in rows))
        self.assertEqual([r[1] for r in rows], sorted(r[1] for r in rows))
        self.assertEqual([r[3] for r in rows][:2], ['a hippopotamus', '"Thriller"'])
        self.assertEqual([r[3] for r in rows][-2:], ['late 1', 'late 2'])

    def test_answer_and_question_columns_are_swapped(self):
        self.build()
        self.assertEqual(
            self.query('SELECT clue, response FROM clues WHERE id = 1'),
            [('Close relative of the pig, though its name means "river horse"',
              'a hippopotamus')])

    def test_escapes_are_removed(self):
        self.build()
        self.assertEqual(self.query('SELECT response FROM clues WHERE id = 2'),
                         [('"Thriller"',)])
        self.assertEqual(
            self.query('SELECT clue, category_comment FROM clues WHERE id = 3'),
            [("It's the largest living land animal", '(Alex: Each one is a mammal.')])

    def test_row_fields(self):
        self.build()
        rows = self.query('''
            SELECT g.air_date, c.round, c.value, c.dd_wager, k.name, c.notes
            FROM clues c
            JOIN games g ON g.id = c.game_id
            JOIN categories k ON k.id = c.category_id
            WHERE c.id IN (3, 4) ORDER BY c.id''')
        self.assertEqual(rows, [
            ('1984-09-11', 2, 800, 1500, 'ANIMALS', None),
            ('1984-09-11', 3, 0, 0, 'WORLD CAPITALS', 'Tournament of Champions game 1.'),
        ])

    def test_clue_key_is_stable_across_rebuilds(self):
        self.build()
        first = self.query('SELECT clue_key FROM clues ORDER BY id')
        # Rebuilding from a file with an extra row first renumbers every clue,
        # but each clue's key must stay the same.
        write_tsv(self.tsv, [['1', '200', '0', 'NEW', '', 'New clue', 'new', '1984-09-09', '']]
                  + SAMPLE_ROWS)
        self.build()
        self.assertEqual(self.query('SELECT clue_key FROM clues WHERE id > 1 ORDER BY id'),
                         first)
        digest = hashlib.sha1(
            '1984-09-10|1|400|ANIMALS|Close relative of the pig, though its name means '
            '"river horse"'.encode('utf-8')).digest()
        self.assertEqual(first[0], (int.from_bytes(digest[:8], 'big', signed=True),))

    def test_meta(self):
        self.build()
        meta = dict(self.query('SELECT key, value FROM meta'))
        self.assertEqual(meta['schema_version'], str(build_clue_db.SCHEMA_VERSION))
        self.assertEqual(meta['dataset_version'], 'test')
        self.assertEqual(meta['source_sha256'], 'abc123')
        self.assertEqual(meta['clue_count'], '6')
        self.assertEqual(meta['dataset_namespace'], 'jwolle1')
        self.assertIn('built_at', meta)

    def test_version_file_matches_meta(self):
        self.build()
        version = json.loads((self.db.parent / 'clues.version').read_text(encoding='utf-8'))
        self.assertEqual(version, dict(self.query('SELECT key, value FROM meta')))
        self.assertEqual(sorted(p.name for p in self.db.parent.iterdir()),
                         ['clues.db', 'clues.version'])

    def test_rejects_unexpected_columns(self):
        write_tsv(self.tsv, [], header='round\tvalue')
        with self.assertRaises(ValueError):
            self.build()
        self.assertFalse(self.db.exists())

    def test_rejects_short_rows(self):
        write_tsv(self.tsv, [['1', '200', '0', 'ANIMALS']])
        with self.assertRaises(ValueError):
            self.build()

    def test_failed_build_keeps_previous_database(self):
        self.build()
        write_tsv(self.tsv, [['1', '200', '0', 'X', '', 'clue', 'resp', 'not-a-date', '']])
        with self.assertRaises(ValueError):
            self.build()
        self.assertEqual(self.query('SELECT COUNT(*) FROM clues'), [(6,)])
        self.assertEqual(list(self.db.parent.glob('*.db')), [self.db])

    def test_main_rejects_checksum_mismatch(self):
        code = build_clue_db.main(['--input', str(self.tsv), '--output', str(self.db),
                                   '--sha256', '0' * 64])
        self.assertEqual(code, 1)
        self.assertFalse(self.db.exists())

    def test_main_skips_checksum_when_empty(self):
        code = build_clue_db.main(['--input', str(self.tsv), '--output', str(self.db),
                                   '--sha256', ''])
        self.assertEqual(code, 0)
        self.assertTrue(self.db.exists())


class MediaReasonTest(unittest.TestCase):
    """Clues taken from the v42 dataset."""

    def assertReason(self, clue, expected):
        self.assertEqual(build_clue_db.media_reason(clue), expected, clue)

    def test_media_clues(self):
        for clue, reason in [
            ("What's this?", 'bare_demonstrative'),
            ("It's the country highlighted here", 'shown_here'),
            ('This country of southeastern Europe is outlined here', 'shown_here'),
            ("It's the big ballet leap being performed here", 'shown_here'),
            ('Geographic name of the instrument featured here in a Mozart concerto', 'shown_here'),
            ('Composer of following famous Concerto No. 1 in B flat minor: '
             '[Instrumental music plays]', 'bracketed_media_cue'),
            ('Victorious & defeated countries portrayed in this overture: '
             '[1812 Overture plays.]', 'bracketed_media_cue'),
            ('Seen on the right, Moe Howard of the Three Stooges really personified this '
             'kitchenware cut', 'photo_position'),
            ('John Callahan, seen at left, pulled together "Juneteenth"', 'photo_position'),
            ("The cheerful tune you're hearing is this composer's overture to "
             '"H.M.S. Pinafore"', 'audio_playing'),
            ('You just heard the rooster do this, also the name of another bird',
             'audio_playing'),
        ]:
            self.assertReason(clue, reason)

    def test_text_clues(self):
        for clue in [
            'Sir Walter tried to stab himself to death while imprisoned here',
            'Manny Sanguillen, John Candelaria & Andy Van Slyke are among the heroes who '
            'have performed here',
            '(Jimmy of the Clue Crew holds the first computer mouse at SRI International.) '
            'The first computer mouse was developed & demonstrated here at SRI',
            '(Kelly of the Clue Crew shows a map on the monitor.) For those who like a '
            'challenge, it takes about six months to hike the nearly 2,200 miles',
            'This man\'s "[love is more thicker than forget]" continues non-capitalization',
            '(Hi, I\'m Lee Goldberg from New York\'s ABC7. [He presents from Plymouth '
            'Church in Brooklyn, New York.]) Plymouth Church was once a stop',
            'Easily seen below the equator, the constellation Crux is popularly known by '
            'this name',
            "What you're listening to when you measure your \"HR\"",
            'Title of the following: "Promise me, Son, not to do the things I\'ve done"',
            "What's this word for a baby kangaroo?",
        ]:
            self.assertReason(clue, None)


if __name__ == '__main__':
    unittest.main()
