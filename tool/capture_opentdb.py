#!/usr/bin/env python3
"""Save real Open Trivia Database responses as test fixtures.

Captures one response of each kind the OpenTDB dialect has to handle (a page
of questions, every response_code, the token and category endpoints) into
test/support/opentdb/, with manifest.json recording each request's URL and
HTTP status. Re-run it to check the app's assumptions against the live API;
see docs/general-trivia-plan.md.

The questions are CC BY-SA 4.0 (opentdb.com), so the saved files are too.

Usage (from the repository root; takes about a minute and a half):
    python3 tool/capture_opentdb.py

Only the Python standard library is required.
"""

import argparse
import concurrent.futures
import datetime
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / 'test' / 'support' / 'opentdb'
DEFAULT_BASE = 'https://opentdb.com'

# The API asks for one request per IP every 5 seconds.
REQUEST_GAP = 6.0
# A category and difficulty with fewer questions than a full batch, for the
# "not enough questions" and "token used up" responses.
SMALL_POOL = {'category': '13', 'difficulty': 'hard'}
# Session tokens are replaced with this in the saved files.
TOKEN_PLACEHOLDER = '0123456789abcdef' * 4
UNKNOWN_TOKEN = '0' * 64
BURST_SIZE = 8
BURST_TRIES = 3


class Capturer:
    def __init__(self, base, gap=REQUEST_GAP):
        self.base = base.rstrip('/')
        self.gap = gap
        self.token = None
        self.manifest = {}
        self.bodies = {}
        self._last = 0.0

    def url(self, path, params):
        query = urllib.parse.urlencode(params)
        return f'{self.base}/{path}' + (f'?{query}' if query else '')

    def fetch(self, path, params, paced=True):
        """Returns (url, HTTP status, body text), pausing between requests."""
        if paced:
            time.sleep(max(0.0, self._last + self.gap - time.monotonic()))
        url = self.url(path, params)
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                status, body = response.status, response.read().decode('utf-8')
        except urllib.error.HTTPError as e:
            status, body = e.code, e.read().decode('utf-8')
        self._last = time.monotonic()
        return url, status, body

    def save(self, name, url, status, body):
        body = self.redact(body)
        self.bodies[name] = body
        entry = {'url': self.redact(url), 'status': status}
        try:
            code = json.loads(body).get('response_code')
        except (ValueError, AttributeError):
            code = None
        if code is not None:
            entry['response_code'] = code
        self.manifest[name] = entry
        print(f'{name}: HTTP {status}, response_code {code}', file=sys.stderr)

    def capture(self, name, path, params):
        url, status, body = self.fetch(path, params)
        self.save(name, url, status, body)
        return json.loads(body)

    def redact(self, text):
        return text.replace(self.token, TOKEN_PLACEHOLDER) if self.token else text

    def run(self):
        self.capture('categories.json', 'api_category.php', {})
        count = self.capture('count_small_pool.json', 'api_count.php',
                             {'category': SMALL_POOL['category']})
        pool_size = count['category_question_count'][
            f"total_{SMALL_POOL['difficulty']}_question_count"]

        _, status, body = self.fetch('api_token.php', {'command': 'request'})
        self.token = json.loads(body)['token']
        self.save('token_request.json', self.url('api_token.php', {'command': 'request'}),
                  status, body)

        # Use up the small pool first: a page of random questions on the same
        # token could take some of it.
        self.capture('random_small_pool.json', 'api.php',
                     {'amount': pool_size, 'encode': 'url3986', 'token': self.token,
                      **SMALL_POOL})
        self.capture('code4_token_empty.json', 'api.php',
                     {'amount': 1, 'encode': 'url3986', 'token': self.token, **SMALL_POOL})
        self.capture('token_reset.json', 'api_token.php',
                     {'command': 'reset', 'token': self.token})
        self.capture('random.json', 'api.php',
                     {'amount': 50, 'encode': 'url3986', 'token': self.token})
        # Asking for more than a filter matches fails outright, even without
        # a token, rather than returning what there is.
        self.capture('code1_no_results.json', 'api.php',
                     {'amount': pool_size + 1, 'encode': 'url3986', **SMALL_POOL})
        self.capture('code2_invalid_parameter.json', 'api.php',
                     {'amount': 0, 'encode': 'url3986'})
        self.capture('code3_token_not_found.json', 'api.php',
                     {'amount': 1, 'encode': 'url3986', 'token': UNKNOWN_TOKEN})
        self.capture_rate_limit()

    def capture_rate_limit(self):
        """Sends bursts of requests until one is refused for going too fast."""
        params = {'amount': 1, 'encode': 'url3986'}
        for _ in range(BURST_TRIES):
            time.sleep(max(0.0, self._last + self.gap - time.monotonic()))
            with concurrent.futures.ThreadPoolExecutor(BURST_SIZE) as pool:
                results = list(pool.map(lambda _: self.fetch('api.php', params, paced=False),
                                        range(BURST_SIZE)))
            for url, status, body in results:
                if json.loads(body).get('response_code') == 5:
                    self.save('code5_rate_limit.json', url, status, body)
                    return
        print('warning: no request was rate limited; code5_rate_limit.json not saved',
              file=sys.stderr)

    def write(self, out):
        out.mkdir(parents=True, exist_ok=True)
        for name, body in self.bodies.items():
            (out / name).write_text(body if body.endswith('\n') else body + '\n',
                                    encoding='utf-8')
        manifest = {
            'captured_at': datetime.date.today().isoformat(),
            'base': self.base,
            **({'token_placeholder': TOKEN_PLACEHOLDER} if self.token else {}),
            'files': self.manifest,
        }
        (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n',
                                           encoding='utf-8')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT,
                        help=f'directory to write (default: {DEFAULT_OUTPUT.relative_to(REPO_ROOT)})')
    parser.add_argument('--base', default=DEFAULT_BASE, help='API base URL')
    args = parser.parse_args(argv)
    capturer = Capturer(args.base)
    capturer.run()
    capturer.write(args.output)
    return 0


if __name__ == '__main__':
    sys.exit(main())
