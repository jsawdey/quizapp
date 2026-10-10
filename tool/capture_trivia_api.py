#!/usr/bin/env python3
"""Save real responses from The Trivia API as test fixtures.

Captures what TheTriviaApiDialect has to handle (a page of questions, a
filtered page, a category with fewer questions than a batch, an unknown
category, a rejected difficulty, and the category list) into
test/support/the_trivia_api/, with manifest.json recording each request's URL
and HTTP status. Re-run it to check the app's assumptions against the live
API; see docs/general-trivia-plan.md.

The questions are CC BY-NC 4.0 (the-trivia-api.com), so the saved files are
too: non-commercial use only.

Usage (from the repository root; takes a few seconds):
    python3 tool/capture_trivia_api.py

Only the Python standard library is required.
"""

import argparse
import sys
from pathlib import Path

from capture_opentdb import Capturer

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / 'test' / 'support' / 'the_trivia_api'
DEFAULT_BASE = 'https://the-trivia-api.com'

# The API allows 20 requests every 5 seconds.
REQUEST_GAP = 1.0

CAPTURES = [
    ('categories.json', 'v2/categories', {}),
    ('questions.json', 'v2/questions', {'limit': 50}),
    ('questions_filtered.json', 'v2/questions',
     {'limit': 20, 'categories': 'geography,music', 'difficulties': 'hard'}),
    # Fewer easy General Knowledge questions than a batch: a short page.
    ('questions_small_pool.json', 'v2/questions',
     {'limit': 50, 'categories': 'general_knowledge', 'difficulties': 'easy'}),
    # Ignored by the API, which sends General Knowledge instead.
    ('questions_unknown_category.json', 'v2/questions', {'limit': 5, 'categories': 'knitting'}),
    # HTTP 400 with a plain-text body.
    ('bad_difficulty.txt', 'v2/questions', {'limit': 5, 'difficulties': 'impossible'}),
]


def run(capturer):
    for name, path, params in CAPTURES:
        url, status, body = capturer.fetch(path, params)
        capturer.save(name, url, status, body)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT,
                        help=f'directory to write (default: {DEFAULT_OUTPUT.relative_to(REPO_ROOT)})')
    parser.add_argument('--base', default=DEFAULT_BASE, help='API base URL')
    args = parser.parse_args(argv)
    capturer = Capturer(args.base, gap=REQUEST_GAP)
    run(capturer)
    capturer.write(args.output)
    return 0


if __name__ == '__main__':
    sys.exit(main())
