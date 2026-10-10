import json
import tempfile
import unittest
from pathlib import Path

import capture_opentdb
from capture_opentdb import TOKEN_PLACEHOLDER, Capturer


class CapturerTest(unittest.TestCase):
    def test_url_omits_an_empty_query(self):
        capturer = Capturer('https://example.test/')
        self.assertEqual(capturer.url('api_category.php', {}),
                         'https://example.test/api_category.php')
        self.assertEqual(capturer.url('api.php', {'amount': 1, 'encode': 'url3986'}),
                         'https://example.test/api.php?amount=1&encode=url3986')

    def test_saved_files_and_manifest_hide_the_token(self):
        capturer = Capturer('https://example.test')
        capturer.token = 'secret' * 8
        capturer.save('token_request.json',
                      'https://example.test/api_token.php?command=request', 200,
                      json.dumps({'response_code': 0, 'token': capturer.token}))
        capturer.save('random.json', f'https://example.test/api.php?token={capturer.token}',
                      429, '{"response_code":5,"result":[]}')
        capturer.save('categories.json', 'https://example.test/api_category.php', 200,
                      '{"trivia_categories":[]}')
        with tempfile.TemporaryDirectory() as tmp:
            capturer.write(Path(tmp))
            texts = {p.name: p.read_text(encoding='utf-8') for p in Path(tmp).iterdir()}
        self.assertTrue(all('secret' not in text for text in texts.values()))
        self.assertEqual(json.loads(texts['token_request.json'])['token'], TOKEN_PLACEHOLDER)
        manifest = json.loads(texts['manifest.json'])
        self.assertEqual(manifest['files']['random.json'], {
            'url': f'https://example.test/api.php?token={TOKEN_PLACEHOLDER}',
            'status': 429, 'response_code': 5})
        self.assertNotIn('response_code', manifest['files']['categories.json'])

    def test_rate_limit_capture_stops_at_the_first_refusal(self):
        capturer = Capturer('https://example.test', gap=0)
        sent = []

        def fetch(path, params, paced=True):
            sent.append(path)
            code = 5 if len(sent) == 3 else 0
            return 'https://example.test/api.php', 429 if code else 200, \
                json.dumps({'response_code': code})

        capturer.fetch = fetch
        capturer.capture_rate_limit()
        self.assertEqual(len(sent), capture_opentdb.BURST_SIZE)
        self.assertEqual(capturer.manifest['code5_rate_limit.json']['status'], 429)


if __name__ == '__main__':
    unittest.main()
