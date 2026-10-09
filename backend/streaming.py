"""Isolated App Server turn with display-only streaming snapshots."""
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time


class StreamError(Exception):
    pass


def partial_fields(text):
    """Parse only complete JSON string characters, including split escapes.

    This is for display only. Final output still requires strict JSON/schema
    validation. Never render raw JSON or attempt to repair a final response.
    """
    result = {}
    index = 0
    length = len(text)

    def whitespace():
        nonlocal index
        while index < length and text[index].isspace():
            index += 1

    def string():
        nonlocal index
        if index >= length or text[index] != '"':
            raise ValueError
        index += 1
        start = index
        safe = start
        while index < length:
            if text[index] == '"':
                value = json.loads('"' + text[start:index] + '"')
                index += 1
                return value, True
            if text[index] == '\\':
                count = 6 if index + 1 < length and text[index + 1] == 'u' else 2
                if index + count > length:
                    break
                index += count
            else:
                index += 1
            safe = index
        value = json.loads('"' + text[start:safe] + '"')
        # Do not write lone UTF-16 surrogate halves into UTF-8 snapshots.
        value = value.encode('utf-8', errors='ignore').decode('utf-8')
        return value, False

    try:
        whitespace()
        if index >= length or text[index] != '{':
            return result
        index += 1
        for _ in range(2):
            whitespace()
            key, complete = string()
            if not complete or key not in ('explanation', 'replacement'):
                break
            whitespace()
            if index >= length or text[index] != ':':
                break
            index += 1
            whitespace()
            value, complete = string()
            result[key] = value
            if not complete:
                break
            whitespace()
            if index >= length or text[index] != ',':
                break
            index += 1
    except (ValueError, json.JSONDecodeError):
        pass
    return result


def run_stream(command, request, prompt, config, workdir, cancel_file, stop_process, classify_error):
    environment = os.environ.copy()
    for key in list(environment):
        if key.startswith('CODEX_') and key not in ('CODEX_HOME', 'CODEX_API_KEY'):
            environment.pop(key, None)
    started = time.monotonic()
    progress_file = workdir / 'progress.json'
    last_progress = 0
    chunks = 0
    thread_id = None
    turn_id = None
    current_item = None
    raw_text = ''
    final_text = ''
    completed = False
    errors = []
    last_content = None
    visible_text = {}
    total_limit = config.get('timeout_seconds', 60)
    first_limit = config.get('first_output_timeout_seconds', 25)
    idle_limit = config.get('idle_timeout_seconds', 20)

    def progress(phase, force=False):
        nonlocal last_progress, last_content, visible_text
        now = time.monotonic()
        fields = partial_fields(raw_text)
        if any(fields.values()) and fields != visible_text:
            last_content = now
            visible_text = fields
        if not force and now - last_progress < 0.1:
            return
        value = {'request_id': request['request_id'], 'phase': phase,
                 'elapsed_seconds': round(now - started, 1), 'chunks': chunks,
                 **fields}
        temporary = progress_file.with_suffix('.tmp')
        try:
            temporary.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
            temporary.replace(progress_file)
            last_progress = now
        except PermissionError:
            # MATLAB may briefly hold the previous snapshot while polling.
            pass

    progress('connecting', True)
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, encoding='utf-8',
                               errors='replace', cwd=workdir, env=environment,
                               creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    messages = queue.Queue()

    def read_messages():
        try:
            for line in process.stdout:
                if len(line) > 4_000_000:
                    messages.put({'oversized': True})
                    break
                try:
                    messages.put(json.loads(line))
                except json.JSONDecodeError:
                    continue
        finally:
            messages.put(None)

    def read_errors():
        for line in process.stderr:
            errors.append(line[-2000:])
            del errors[:-4]

    reader = threading.Thread(target=read_messages, daemon=True)
    error_reader = threading.Thread(target=read_errors, daemon=True)
    reader.start()
    error_reader.start()

    def send(message):
        process.stdin.write(json.dumps(message, ensure_ascii=False) + '\n')
        process.stdin.flush()

    def next_message():
        while True:
            if cancel_file.exists():
                if thread_id and turn_id:
                    try:
                        send({'id': 99, 'method': 'turn/interrupt',
                              'params': {'threadId': thread_id, 'turnId': turn_id}})
                    except (OSError, ValueError):
                        pass
                raise StreamError('请求已取消，未修改代码。')
            now = time.monotonic()
            if now - started > total_limit:
                raise StreamError('模型请求超时，未修改代码。')
            if first_limit > 0 and last_content is None and now - started > first_limit:
                raise StreamError('模型在规定时间内未返回可显示的回答，已停止等待。请重试或切换模型。')
            if idle_limit > 0 and last_content is not None and now - last_content > idle_limit:
                raise StreamError('模型回答已停止更新，已结束请求；不完整代码不能插入。请重试。')
            try:
                message = messages.get(timeout=0.1)
            except queue.Empty:
                progress('streaming' if chunks else ('generating' if thread_id else 'connecting'))
                continue
            if message is None:
                raise StreamError(classify_error(''.join(errors)))
            if not isinstance(message, dict) or message.get('oversized'):
                raise StreamError('模型事件格式无效或过长。')
            return message

    def event(message):
        nonlocal turn_id, raw_text, final_text, current_item, chunks, completed
        method = message.get('method', '')
        if method and 'id' in message:
            send({'id': message['id'], 'error': {'code': -32601, 'message': 'Tools and approvals are unavailable'}})
            raise StreamError('模型尝试了交互或工具操作，已拒绝该响应。')
        params = message.get('params', {})
        if params.get('threadId') != thread_id or thread_id is None:
            return
        if method == 'turn/started':
            turn_id = params['turn']['id']
            progress('generating', True)
        if turn_id and params.get('turnId', turn_id) != turn_id:
            return
        if method in ('item/started', 'item/completed'):
            item = params.get('item', {})
            kind = item.get('type')
            if kind not in ('userMessage', 'agentMessage', 'reasoning', 'plan', 'contextCompaction'):
                raise StreamError('模型尝试了工具操作，已拒绝该响应。')
            if kind == 'agentMessage':
                if current_item != item.get('id'):
                    current_item = item.get('id')
                    raw_text = ''
                if method == 'item/completed':
                    raw_text = item.get('text', '')
                    if item.get('phase') in (None, 'final_answer'):
                        final_text = raw_text
                    progress('validating', True)
        elif method == 'item/agentMessage/delta':
            if current_item != params.get('itemId'):
                current_item = params.get('itemId')
                raw_text = ''
            raw_text += params.get('delta', '')
            chunks += 1
            if len(raw_text) > 2_500_000:
                raise StreamError('模型返回内容过长。')
            progress('streaming')
        elif method == 'turn/completed':
            turn = params['turn']
            if turn_id and turn.get('id') != turn_id:
                return
            if turn['status'] != 'completed':
                raise StreamError(classify_error(json.dumps(turn.get('error', {})) + '\n' + ''.join(errors)))
            completed = True
        elif method == 'error':
            # Interactive requests must not silently enter the CLI retry loop.
            raise StreamError(classify_error(json.dumps(params.get('error', {})) + '\n' + ''.join(errors)))

    def receive(request_id):
        while True:
            message = next_message()
            if message.get('id') == request_id and not message.get('method'):
                if 'error' in message:
                    error_text=json.dumps(message['error'])
                    if 'requires experimentalApi' in error_text:
                        raise StreamError('当前 Codex 接口要求启用 experimentalApi 协议能力。')
                    stage={1:'初始化',2:'创建对话',3:'开始生成'}.get(request_id,'通信')
                    raise StreamError(stage+'失败（RPC '+str(message['error'].get('code','unknown'))+'）：'+classify_error(error_text))
                return message['result']
            event(message)

    try:
        send({'id': 1, 'method': 'initialize', 'params': {
            'clientInfo': {'name': 'matlab_ai_assistant', 'version': '0.3.0'}}})
        receive(1)
        send({'method': 'initialized', 'params': {}})
        instructions = (Path(__file__).parent / 'model_instructions.md').read_text(encoding='utf-8')
        send({'id': 2, 'method': 'thread/start', 'params': {
            'model': request['model'], 'cwd': str(workdir), 'ephemeral': True,
            'approvalPolicy': 'never', 'sandbox': 'read-only',
            'baseInstructions': instructions, 'developerInstructions': ''}})
        thread_id = receive(2)['thread']['id']
        progress('generating', True)
        schema = json.loads((Path(__file__).parent / 'response.schema.json').read_text(encoding='utf-8'))
        send({'id': 3, 'method': 'turn/start', 'params': {
            'threadId': thread_id, 'input': [{'type': 'text', 'text': prompt}],
            'model': request['model'], 'effort': request.get('reasoning_effort') or 'low',
            'approvalPolicy': 'never', 'sandboxPolicy': {'type': 'readOnly'},
            'outputSchema': schema}})
        turn_id = receive(3)['turn']['id']
        while not completed:
            event(next_message())
        if cancel_file.exists():
            raise StreamError('请求已取消，未修改代码。')
        try:
            result = json.loads(final_text)
        except (ValueError, TypeError):
            raise StreamError('模型返回的 JSON 无效，未产生修改。') from None
        progress('validating', True)
        return result, chunks
    finally:
        stop_process(process)
        reader.join(timeout=3)
        error_reader.join(timeout=3)
        for stream in (process.stdin, process.stdout, process.stderr):
            stream.close()
