import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import worker


class BackendTests(unittest.TestCase):
    def test_gateway_and_stream_errors_have_actionable_safe_messages(self):
        for raw in ('502 Bad Gateway', '503 Service Unavailable', '504 Gateway Timeout',
                    'upstream failure', 'serverOverloaded', 'responseStreamDisconnected',
                    'responseStreamConnectionFailed', 'responseTooManyFailedAttempts retry limit'):
            with self.subTest(raw=raw):
                result = worker.classify_error(raw + ' Bearer FAKE_SECRET_SENTINEL')
                self.assertIn('连接失败', result)
                self.assertNotIn('FAKE_SECRET_SENTINEL', result)

    def test_run_log_persists_only_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(worker, 'HERE', Path(directory) / 'backend'):
                worker.write_run_log('request_1', False, 22.4, 'request_failed',
                                     worker.classify_error('502 Bearer FAKE_SECRET_SENTINEL'))
                worker.write_run_log('request_2', True, 4.0, '', '')
                logs = list((Path(directory) / 'output' / 'logs').glob('*.jsonl'))
                self.assertEqual(len(logs), 1)
                text = logs[0].read_text(encoding='utf-8')
                self.assertNotIn('FAKE_SECRET_SENTINEL', text)
                records = [json.loads(line) for line in text.splitlines()]
                self.assertEqual(len(records), 2)
                self.assertEqual(records[0]['request_id'], 'request_1')
                self.assertFalse(records[0]['ok'])
                self.assertTrue(records[1]['ok'])
                self.assertEqual(set(records[0]), {'timestamp_utc', 'request_id', 'ok',
                    'elapsed_seconds', 'error_type', 'message'})

    def test_logging_failure_does_not_break_request(self):
        with patch.object(Path, 'mkdir', side_effect=PermissionError):
            worker.write_run_log('test_1', True, 1.0, '', '')

    def request(self, mode='edit'):
        return {'request_id': 'test_001', 'question': '修复平方',
                'code': 'x * x', 'mode': mode, 'model': 'configured-model'}

    def test_request_limits(self):
        request = self.request()
        request['code'] = 'a' * (worker.MAX_CODE + 1)
        with self.assertRaises(worker.RequestError):
            worker.validate_request(request)

    def test_generation_uses_only_requirement(self):
        request = self.request('generate')
        request['code'] = ''
        worker.validate_request(request)
        worker.validate_response({'explanation': 'example', 'replacement': 't=0:0.1:1;'}, 'generate')
        request['code'] = 'unexpected editor contents'
        with self.assertRaises(worker.RequestError):
            worker.validate_request(request)

    def test_cursor_context_must_match(self):
        request = self.request('complete')
        request.update(before_cursor='wrong', after_cursor='')
        with self.assertRaises(worker.RequestError):
            worker.validate_request(request)

    def test_help_requires_read_only_context_and_empty_replacement(self):
        request = self.request('help')
        request.update(code='', help_context={'documents': [{'id': 'H1', 'topic': 'fft', 'text': 'Local help'}]})
        worker.validate_request(request)
        payload = json.loads(worker.request_prompt(request).split('\n', 1)[1])
        self.assertEqual(payload['help_context']['documents'][0]['topic'], 'fft')
        worker.validate_response({'explanation': '用途 [H1]', 'replacement': ''}, 'help')
        answer = worker.response_with_sources({'explanation': '用途 [H1]', 'replacement': ''}, request)
        self.assertIn('[H1] 本机 MATLAB help fft', answer['explanation'])
        self.assertEqual(answer['replacement'], '')
        with self.assertRaises(worker.RequestError):
            worker.validate_response({'explanation': '用途', 'replacement': 'fft(x)'}, 'help')
        request['code'] = 'PRIVATE_EDITOR'
        with self.assertRaises(worker.RequestError):
            worker.validate_request(request)

    def test_help_never_accepts_code_history(self):
        request = self.request('help')
        request.update(code='', help_context={'documents': []}, history=[{
            'question': 'previous', 'mode': 'generate', 'explanation': '', 'replacement': 'PRIVATE_EDITOR'}])
        with self.assertRaises(worker.RequestError):
            worker.validate_request(request)
        request['history'][0].update(mode='help', replacement='')
        worker.validate_request(request)
        request['help_context']['documents'] = {}
        with self.assertRaises(worker.RequestError):
            worker.validate_request(request)

    def test_explanation_rejects_edits(self):
        with self.assertRaises(worker.RequestError):
            worker.validate_response({'explanation': 'test', 'replacement': 'x=2;'}, 'explain')

    def test_incomplete_responses_rejected(self):
        for response in ({}, {'explanation': '', 'replacement': None},
                         {'explanation': '', 'replacement': ''},
                         {'explanation': '', 'replacement': '```matlab\nx=1;\n```'},
                         {'explanation': '', 'replacement': 'x=1;', 'extra': 'bad'}):
            with self.subTest(response=response), self.assertRaises(worker.RequestError):
                worker.validate_response(response, 'edit')

    def test_html_escapes_code(self):
        rendered = worker.diff_html('x=1;', '<script>bad()</script>')
        self.assertNotIn('<script>', rendered)
        self.assertIn('&lt;script&gt;', rendered)

    def run_fake(self, mode, cancel=False):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            output = folder / 'model-response.json'
            marker = folder / 'cancel.flag'
            if cancel:
                cancellation = threading.Timer(0.2, marker.touch)
                cancellation.start()
            code = ('import pathlib,sys,time,json; '
                    'sys.stdin.read(); '
                    + ('time.sleep(10); ' if mode == 'slow' else '')
                    + ('sys.stderr.write("401 Bearer FAKE_SECRET_SENTINEL"); sys.exit(1); ' if mode == 'auth' else '')
                    + f'pathlib.Path({str(output)!r}).write_text(' 
                    + repr('{broken' if mode == 'invalid' else json.dumps({'explanation': 'ok', 'replacement': 'x.^2'}))
                    + ',encoding="utf-8"); '
                    + ('print(json.dumps({"item":{"type":"file_change"}}))' if mode == 'tool' else 'print("{}")'))
            with patch.object(worker, 'codex_command', return_value=([sys.executable, '-c', code], 'test')):
                try:
                    return worker.run_request(self.request(), {'timeout_seconds': 0.1 if mode == 'slow' and not cancel else 5}, folder, marker)
                finally:
                    if cancel:
                        cancellation.cancel()
                    self.assertFalse(output.exists(), 'Raw model response must be removed')

    def test_subprocess_response(self):
        self.assertEqual(self.run_fake('valid')['replacement'], 'x.^2')

    def test_invalid_json_never_succeeds(self):
        with self.assertRaises(worker.RequestError):
            self.run_fake('invalid')

    def test_unexpected_tools_rejected(self):
        with self.assertRaises(worker.RequestError):
            self.run_fake('tool')

    def test_cancellation(self):
        with self.assertRaisesRegex(worker.RequestError, '取消'):
            self.run_fake('slow', cancel=True)

    def test_timeout(self):
        with self.assertRaisesRegex(worker.RequestError, '超时'):
            self.run_fake('slow')

    def test_auth_error_does_not_leak_raw_error(self):
        with self.assertRaises(worker.RequestError) as caught:
            self.run_fake('auth')
        self.assertNotIn('FAKE_SECRET_SENTINEL', str(caught.exception))
        self.assertIn('鉴权', str(caught.exception))


if __name__ == '__main__':
    unittest.main(verbosity=2)
