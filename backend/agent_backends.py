"""Claude Code and experimental DSH adapters. Only MATLAB applies edits."""
from collections import deque
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time

from backend_config import executable_command
from backend_errors import RequestError
from streaming import partial_fields

HERE = Path(__file__).resolve().parent


def claude_command(config):
    # safe-mode preserves authentication, unlike bare mode. Tools are separately disabled.
    return executable_command(config, 'claude') + [
        '--safe-mode', '-p', '--output-format', 'stream-json', '--verbose',
        '--include-partial-messages', '--tools', '', '--disallowedTools', '*',
        '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
        '--settings', '{"disableAllHooks":true}', '--permission-mode', 'dontAsk',
        '--no-session-persistence', '--system-prompt-file', str(HERE / 'model_instructions.md'),
        '--json-schema', (HERE / 'response.schema.json').read_text(encoding='utf-8')]


class AgentEvents:
    """Translate provider events; reject tool calls and incomplete final results."""
    def __init__(self, name, session_id):
        self.name, self.session_id = name, session_id
        self.text = ''
        self.final = None
        self.done = False
        self.chunks = 0
        self.reason = None
        self.received = False
        self.message_id = None
        self.structured_ids = set()

    def content(self, blocks):
        for block in blocks:
            if block.get('type') in ('tool_use', 'tool_call', 'tool_result'):
                if self.name == 'claude' and block.get('type') == 'tool_use' and block.get('name') == 'StructuredOutput':
                    self.structured_ids.add(block.get('id'))
                    continue
                if self.name == 'claude' and block.get('type') == 'tool_result' and block.get('tool_use_id') in self.structured_ids:
                    continue
                raise RequestError('Agent 尝试调用工具，响应已拒绝。')
        return ''.join(b.get('text', '') for b in blocks if b.get('type') == 'text')

    def accept(self, event, classify):
        if not isinstance(event, dict):
            raise RequestError('Agent 事件格式无效。')
        if self.name == 'claude':
            kind = event.get('type')
            if kind == 'system' and event.get('subtype') == 'init':
                if set(event.get('tools', [])) - {'StructuredOutput'} or event.get('mcp_servers'):
                    raise RequestError('Claude 未成功禁用工具，请检查受支持版本及组织策略。')
            elif kind == 'stream_event':
                inner = event.get('event', {})
                self.content([inner.get('content_block', {})])
                delta = inner.get('delta', {})
                if delta.get('type') == 'text_delta':
                    self.text += delta.get('text', '')
                    self.chunks += 1
            elif kind == 'assistant':
                self.text = self.content(event.get('message', {}).get('content', []))
            elif kind == 'user':
                self.content(event.get('message', {}).get('content', []))
            elif kind == 'result':
                if event.get('is_error') or event.get('subtype') != 'success':
                    raise RequestError(classify(json.dumps(event)))
                self.final = event.get('structured_output')
                if self.final is None:
                    self.final = json.loads(event.get('result', ''))
                self.done = True
        else:
            params = event.get('params', {})
            if 'error' in event:
                raise RequestError(classify(json.dumps(event['error'])))
            if params.get('sessionId') != self.session_id:
                return
            if event.get('method') == 'session.event':
                body = params.get('event', {})
                kind, data = body.get('type', ''), body.get('data', {})
                if kind.startswith('tool/') or kind.startswith('tool_call'):
                    raise RequestError('DeepSeek Harness 尝试调用工具，响应已拒绝。')
                if kind == 'agent/inbox/spliced':
                    self.received = any(m.get('id') == self.message_id for m in data.get('inserted', []))
                if not self.received:
                    return
                if kind == 'assistant/message':
                    self.text = self.content(data.get('message', data).get('content', []))
                    self.chunks += 1
                elif kind == 'turn/end':
                    self.reason = data.get('reason', {}).get('kind')
            elif event.get('method') == 'session.status' and params.get('status') == 'idle' and self.received:
                if self.reason != 'completed':
                    raise RequestError('DeepSeek Harness 未完整完成回答，未产生修改。')
                self.final = json.loads(self.text)
                self.done = True


def run_agent(name, request, prompt, config, workdir, cancel_file, stop_process, classify):
    env = os.environ.copy()
    state = AgentEvents(name, request['request_id'])
    try:
        if name == 'claude':
            command = claude_command(config)
            if request['model'] != '__default__':
                command += ['--model', request['model']]
        else:
            command = executable_command(config, name) + ['--profile', 'sdk-minimal', '--patch',
                                                         str(HERE / 'dsh-no-tools.patch.yml')]
            # No user profiles/plugins/tools. Only explicitly inherited model credentials.
            for key in list(env):
                if key.startswith('DSH_'):
                    env.pop(key)
            env['DSH_HOME'] = str(workdir / 'dsh-home')
            env['DSH_SYSTEM_PROMPT'] = (HERE / 'model_instructions.md').read_text(encoding='utf-8')
            env['DSH_TELEMETRY_DISABLED'] = '1'
    except ValueError as error:
        raise RequestError(str(error)) from None
    started = time.monotonic()
    last_content = None
    last_fields = {}
    messages, errors = queue.Queue(maxsize=256), deque(maxlen=4)
    process = subprocess.Popen(command, cwd=workdir, env=env, stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding='utf-8', errors='replace',
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    stopping = threading.Event()

    def put(item):
        while not stopping.is_set():
            try:
                messages.put(item, timeout=0.1)
                return
            except queue.Full:
                pass

    def read():
        try:
            while True:
                line = process.stdout.readline(4_000_001)
                if not line:
                    break
                if len(line) > 4_000_000:
                    put({'invalid': True})
                    break
                try:
                    put(json.loads(line))
                except ValueError:
                    put({'invalid': True})
                    break
        finally:
            put(None)

    def stderr():
        for line in process.stderr:
            errors.append(line[-2000:])

    reader = threading.Thread(target=read, daemon=True)
    error_reader = threading.Thread(target=stderr, daemon=True)
    reader.start(); error_reader.start()

    def send(value):
        process.stdin.write(json.dumps(value, ensure_ascii=False) + '\n')
        process.stdin.flush()

    def snapshot():
        nonlocal last_content, last_fields
        if len(state.text) > 2_500_000:
            raise RequestError('模型返回内容过长。')
        fields = partial_fields(state.text)
        if any(fields.values()) and fields != last_fields:
            last_content = time.monotonic()
            last_fields = fields
        temp = workdir / 'progress.tmp'
        try:
            temp.write_text(json.dumps({'request_id': request['request_id'],
                'phase': 'streaming' if fields else 'generating', 'chunks': state.chunks,
                'elapsed_seconds': round(time.monotonic()-started, 1), **fields}, ensure_ascii=False), encoding='utf-8')
            temp.replace(workdir / 'progress.json')
        except PermissionError:
            pass

    try:
        if name == 'claude':
            # Writer thread avoids blocking cancellation for a large stdin payload.
            def write_prompt():
                try:
                    process.stdin.write(prompt)
                    process.stdin.close()
                except (OSError, ValueError):
                    pass
            writer = threading.Thread(target=write_prompt, daemon=True)
            writer.start()
        else:
            send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {
                'cwd': str(workdir), 'provider': 'deepseek-official', 'model': request['model']}})
        pending = []
        while not state.done:
            now = time.monotonic()
            if cancel_file.exists():
                raise RequestError('请求已取消，未修改代码。')
            if now-started > config['timeout_seconds']:
                raise RequestError('模型请求超时，未修改代码。')
            first, idle = config['first_output_timeout_seconds'], config['idle_timeout_seconds']
            if first > 0 and last_content is None and now-started > first:
                raise RequestError('首次回答等待超时。可在“后端与等待设置”增加等待时间。')
            if idle > 0 and last_content is not None and now-last_content > idle:
                raise RequestError('回答中断等待超时，不完整代码不能应用。')
            try:
                event = messages.get(timeout=0.15)
            except queue.Empty:
                snapshot()
                continue
            if event is None:
                error_reader.join(timeout=0.2)
                raise RequestError(classify(''.join(errors)))
            if event.get('invalid'):
                raise RequestError('Agent 协议不兼容或输出过长，请检查版本。')
            if name == 'deepseek_harness' and 'method' in event and 'id' in event:
                raise RequestError('DeepSeek Harness 请求了未支持的交互操作。')
            if name == 'deepseek_harness' and 'error' in event:
                raise RequestError(classify(json.dumps(event['error'])))
            if name == 'deepseek_harness' and event.get('id') == 1:
                server = event.get('result', {}).get('serverInfo', {})
                if server.get('name') != 'deepseek-harness-sdk-runtime' or server.get('version') != '0.0.1':
                    raise RequestError('DeepSeek Harness SDK 握手失败或协议版本不兼容。')
                send({'jsonrpc': '2.0', 'id': 2, 'method': 'session/prompt', 'params': {
                    'sessionId': request['request_id'], 'contentBlocks': [{'type': 'text', 'text': prompt}]}})
            elif name == 'deepseek_harness' and event.get('id') == 2:
                state.message_id = event.get('result', {}).get('messageId')
                if not state.message_id:
                    raise RequestError('DeepSeek Harness 未接受请求。')
                for queued in pending:
                    state.accept(queued, classify)
                pending.clear()
            elif name == 'deepseek_harness' and state.message_id is None and 'error' not in event:
                if len(pending) >= 256:
                    raise RequestError('DeepSeek Harness 启动事件过多。')
                pending.append(event)
            else:
                state.accept(event, classify)
            snapshot()
        if cancel_file.exists():
            raise RequestError('请求已取消，未修改代码。')
        return state.final, state.chunks
    except (ValueError, TypeError, AttributeError):
        raise RequestError('Agent 返回格式不兼容，未产生修改。') from None
    finally:
        stopping.set()
        stop_process(process)
        reader.join(timeout=2); error_reader.join(timeout=2)
        for stream in (process.stdin, process.stdout, process.stderr):
            if not stream.closed:
                stream.close()
