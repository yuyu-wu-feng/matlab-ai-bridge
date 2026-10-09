import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import streaming
import worker

FAKE_SERVER = r'''
import json, sys, time
sys.stdin.reconfigure(encoding='utf-8')
sys.stdout.reconfigure(encoding='utf-8')
def send(value):
    print(json.dumps(value), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if method == 'initialize':
        send({'id': request['id'], 'result': {}})
    elif method == 'thread/start':
        assert request['params']['ephemeral'] is True
        assert request['params']['sandbox'] == 'read-only'
        send({'id': request['id'], 'result': {'thread': {'id': 'thread1'}}})
    elif method == 'turn/start':
        send({'id': request['id'], 'result': {'turn': {'id': 'turn1'}}})
        common = {'threadId': 'thread1', 'turnId': 'turn1'}
        if sys.argv[1] == 'gateway':
            send({'method': 'error', 'params': {**common, 'willRetry': True,
                  'error': {'message': 'upstream failure FAKE_SECRET_SENTINEL',
                            'codexErrorInfo': {'httpConnectionFailed': {'httpStatusCode': 502}}}}})
            time.sleep(10)
            continue
        if sys.argv[1] == 'reasoning':
            for _ in range(100):
                send({'method': 'item/started', 'params': {**common, 'item': {'type': 'reasoning'}}})
                time.sleep(0.05)
            continue
        if sys.argv[1] == 'retry':
            send({'method': 'error', 'params': {**common, 'willRetry': True, 'error': {'message': 'connection failed'}}})
            time.sleep(10)
            continue
        if sys.argv[1] == 'tool':
            send({'method': 'item/started', 'params': {**common, 'item': {'type': 'commandExecution'}}})
            continue
        raw = json.dumps({'explanation': '中文说明', 'replacement': 'x=1;\ny=x;'}, ensure_ascii=False)
        for index in range(0, len(raw), 3):
            send({'method': 'item/agentMessage/delta', 'params': {**common, 'itemId': 'answer', 'delta': raw[index:index+3]}})
            time.sleep(0.01)
        if sys.argv[1] == 'slow':
            time.sleep(10)
        if sys.argv[1] == 'invalid':
            raw = '{broken'
        send({'method': 'item/completed', 'params': {**common, 'item': {'id': 'answer', 'type': 'agentMessage', 'phase': 'final_answer', 'text': raw}}})
        send({'method': 'turn/completed', 'params': {'threadId': 'thread1', 'turn': {'id': 'turn1', 'status': 'completed'}}})
'''


class StreamingTests(unittest.TestCase):
    def test_partial_json_escapes_at_every_boundary(self):
        response = {'explanation': '中文 "quote" \\ path\nline 😀', 'replacement': 'disp("中");\nx=1;'}
        for ascii_only in (False, True):
            raw = json.dumps(response, ensure_ascii=ascii_only)
            for index in range(len(raw)+1):
                partial = streaming.partial_fields(raw[:index])
                for key, value in partial.items():
                    self.assertTrue(response[key].startswith(value), repr((index, value)))
                    value.encode('utf-8')
            self.assertEqual(streaming.partial_fields(raw), response)

    def test_nested_field_names_in_values_are_not_parsed(self):
        raw = json.dumps({'explanation': 'say "replacement": "wrong"', 'replacement': 'right'})
        self.assertEqual(streaming.partial_fields(raw)['replacement'], 'right')

    def run_fake(self, mode='valid', cancel=False, timeout=5, **limits):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            server = folder / 'server.py'
            server.write_text(FAKE_SERVER, encoding='utf-8')
            marker = folder / 'cancel.flag'
            request = {'request_id': 'stream_1', 'model': 'test'}
            observed = []
            def inspect():
                deadline = time.monotonic()+4
                while time.monotonic()<deadline:
                    try:
                        value = json.loads((folder / 'progress.json').read_text(encoding='utf-8'))
                        if value.get('replacement'):
                            observed.append(value)
                            if cancel:
                                marker.touch()
                            return
                    except (OSError, ValueError):
                        pass
                    time.sleep(0.02)
            observer = threading.Thread(target=inspect)
            if mode == 'slow':
                observer.start()
            try:
                result, chunks = streaming.run_stream([sys.executable, '-u', str(server), mode], request,
                    'test', {'timeout_seconds': timeout, **limits}, folder, marker, worker.stop_process, worker.classify_error)
                self.assertGreater(chunks, 5)
                return result
            finally:
                if observer.is_alive():
                    observer.join(timeout=5)
                if cancel:
                    self.assertTrue(observed, 'Expected visible content before cancellation')

    def test_real_subprocess_stream_success(self):
        self.assertEqual(self.run_fake()['explanation'], '中文说明')

    def test_cancel_after_partial_content(self):
        with self.assertRaisesRegex(streaming.StreamError, '取消'):
            self.run_fake('slow', cancel=True)

    def test_stream_timeout(self):
        with self.assertRaisesRegex(streaming.StreamError, '超时'):
            self.run_fake('slow', timeout=0.5)

    def test_reasoning_heartbeats_do_not_extend_first_output_deadline(self):
        with self.assertRaisesRegex(streaming.StreamError, '未返回可显示'):
            self.run_fake('reasoning', first_output_timeout_seconds=0.4)

    def test_disabled_first_limit_still_has_total_deadline(self):
        with self.assertRaisesRegex(streaming.StreamError, '模型请求超时'):
            self.run_fake('reasoning', timeout=0.6, first_output_timeout_seconds=0)

    def test_disabled_idle_limit_still_has_total_deadline(self):
        with self.assertRaisesRegex(streaming.StreamError, '模型请求超时'):
            self.run_fake('slow', timeout=1, idle_timeout_seconds=0)

    def test_stalled_visible_output_is_stopped(self):
        with self.assertRaisesRegex(streaming.StreamError, '停止更新'):
            self.run_fake('slow', idle_timeout_seconds=0.4)

    def test_connection_failure_does_not_silently_retry(self):
        started = time.monotonic()
        with self.assertRaisesRegex(streaming.StreamError, '连接失败'):
            self.run_fake('retry')
        self.assertLess(time.monotonic()-started, 4)

    def test_gateway_failure_is_specific_and_does_not_leak_details(self):
        with self.assertRaises(streaming.StreamError) as caught:
            self.run_fake('gateway')
        self.assertIn('网关', str(caught.exception))
        self.assertNotIn('FAKE_SECRET_SENTINEL', str(caught.exception))

    def test_final_json_must_be_valid(self):
        with self.assertRaisesRegex(streaming.StreamError, 'JSON'):
            self.run_fake('invalid')

    def test_tool_activity_rejected(self):
        with self.assertRaisesRegex(streaming.StreamError, '工具'):
            self.run_fake('tool')

    def test_history_is_bounded_and_current_code_is_distinct(self):
        request = {'request_id': 'history_1', 'question': 'fix it', 'mode': 'edit', 'model': 'test', 'code': 'CURRENT'}
        turn = {'question': 'old question', 'mode': 'generate', 'replacement': 'OLD', 'explanation': 'old answer'}
        request['history'] = [turn]
        worker.validate_request(request)
        payload = json.loads(worker.request_prompt(request).split('\n', 1)[1])
        self.assertEqual(payload['code'], 'CURRENT')
        self.assertEqual(payload['history'][0]['replacement'], 'OLD')
        request['history'] = [turn]*7
        with self.assertRaises(worker.RequestError):
            worker.validate_request(request)
        request['history'] = [{**turn, 'replacement': 'x'*600001}]
        with self.assertRaises(worker.RequestError):
            worker.validate_request(request)


if __name__ == '__main__':
    unittest.main(verbosity=2)
