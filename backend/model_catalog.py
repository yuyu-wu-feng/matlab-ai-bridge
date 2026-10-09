"""Read the local Codex model picker catalog; never start a model turn."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time
import tomllib


def normalize_models(rows, source):
    if not isinstance(rows, list):
        raise ValueError('Invalid model list')
    models = []
    seen = set()
    for row in rows:
        if not isinstance(row, dict) or row.get('hidden') or row.get('visibility', 'list') != 'list':
            continue
        if row.get('supported_in_api') is False:
            continue
        modalities = row.get('inputModalities', row.get('input_modalities', ['text']))
        if not isinstance(modalities, list) or 'text' not in modalities:
            continue
        model_id = row.get('model') or row.get('slug') or row.get('id')
        if not isinstance(model_id, str) or not model_id.strip() or len(model_id) > 200 or any(ord(c) < 32 for c in model_id):
            continue
        if model_id in seen:
            continue
        seen.add(model_id)
        effort = row.get('defaultReasoningEffort', row.get('default_reasoning_level', ''))
        if effort not in ('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'):
            effort = ''
        models.append({'id': model_id, 'name': str(row.get('displayName') or row.get('display_name') or model_id),
                       'effort': effort, 'source': source})
    return models


def read_rpc_models(executable, cwd, timeout=15):
    environment = os.environ.copy()
    for key in list(environment):
        if key.startswith('CODEX_') and key not in ('CODEX_HOME', 'CODEX_API_KEY'):
            environment.pop(key, None)
    prefix = executable if isinstance(executable, list) else [executable]
    command = prefix + ['app-server', '--stdio', '-c', 'features.plugins=false',
               '-c', 'features.apps=false', '-c', 'features.hooks=false']
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True, encoding='utf-8',
                               errors='replace', cwd=cwd, env=environment,
                               creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    messages = queue.Queue()

    def read_messages():
        try:
            for line in process.stdout:
                try:
                    messages.put(json.loads(line))
                except json.JSONDecodeError:
                    continue
        finally:
            messages.put(None)

    reader = threading.Thread(target=read_messages, daemon=True)
    reader.start()
    deadline = time.monotonic() + timeout

    def send(message):
        process.stdin.write(json.dumps(message) + '\n')
        process.stdin.flush()

    def receive(request_id):
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('Model listing timed out')
            message = messages.get(timeout=remaining)
            if message is None:
                raise RuntimeError('Model listing process exited')
            if isinstance(message, dict) and message.get('id') == request_id:
                if 'error' in message:
                    raise RuntimeError('Model listing RPC failed')
                return message['result']

    try:
        send({'id': 1, 'method': 'initialize', 'params': {
            'clientInfo': {'name': 'matlab_ai_model_picker', 'version': '0.2.0'}}})
        receive(1)
        send({'method': 'initialized', 'params': {}})
        rows = []
        cursor = None
        seen_cursors = set()
        for page in range(20):
            request_id = page + 2
            params = {'limit': 100, 'includeHidden': False}
            if cursor:
                params['cursor'] = cursor
            send({'id': request_id, 'method': 'model/list', 'params': params})
            result = receive(request_id)
            if not isinstance(result, dict) or not isinstance(result.get('data'), list):
                raise ValueError('Invalid catalog response')
            rows.extend(result['data'])
            cursor = result.get('nextCursor')
            if not cursor:
                return rows
            if not isinstance(cursor, str) or cursor in seen_cursors:
                raise ValueError('Invalid catalog pagination')
            seen_cursors.add(cursor)
        raise ValueError('Too many catalog pages')
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
        process.stdin.close()
        reader.join(timeout=2)
        process.stdout.close()


def discover(config, root, codex_home=None):
    from backend_config import backend_name, executable_command
    name = backend_name(config)
    if name != 'codex':
        preferred = config.get('model') or ('__default__' if name == 'claude' else '')
        warning = '模型来自本地配置，不代表已验证账户权限。'
        try:
            command = executable_command(config, name)
            check = subprocess.run(command + ['--version'], capture_output=True, timeout=10,
                encoding='utf-8', errors='replace',
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
            if check.returncode:
                warning = 'Agent 版本检查失败，请检查安装；尚未调用模型。'
        except (ValueError, OSError, subprocess.TimeoutExpired):
            warning = '未检测到可用 Agent，请在“后端与等待设置”配置程序路径；尚未调用模型。'
        models = [{'id': preferred, 'name': preferred, 'effort': '', 'source': 'config'}] if preferred else []
        if name == 'deepseek_harness':
            warning += ' DeepSeek Harness 为实验性 SDK 适配，需填写明确模型 ID。'
        return {'ok': bool(models), 'models': models, 'source': 'config',
                'selected': preferred, 'warning': warning}
    home = Path(codex_home or os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))
    settings = {}
    try:
        settings = tomllib.loads((home / 'config.toml').read_text(encoding='utf-8-sig'))
    except (OSError, ValueError):
        pass
    preferred = config.get('model') or settings.get('model') or ''
    models = []
    source = 'codex'
    warning = ''
    try:
        executable = config.get('codex_executable') or executable_command(config, 'codex')
        if isinstance(executable, str) and Path(executable).suffix.lower() in ('.js', '.mjs', '.cjs', '.cmd', '.bat', '.ps1'):
            executable = executable_command(config, 'codex')
        models = normalize_models(read_rpc_models(executable, root), 'codex')
        if not models:
            raise ValueError('Empty catalog')
    except Exception:
        source = 'cache'
        warning = '无法刷新 Codex 模型目录，当前显示本地缓存。'
        # Only a configured catalog or the standard Codex cache is eligible.
        # Never merge catalogs belonging to an inactive provider.
        catalog_path = settings.get('model_catalog_json')
        candidates = []
        if isinstance(catalog_path, str) and catalog_path:
            path = Path(catalog_path).expanduser()
            candidates.append(path if path.is_absolute() else home / path)
        candidates.append(home / 'models_cache.json')
        for path in candidates:
            try:
                cached = json.loads(path.read_text(encoding='utf-8-sig'))
                models = normalize_models(cached.get('models', []), 'cache')
                if models:
                    break
            except (OSError, ValueError, AttributeError):
                continue
    # Keep an explicitly configured model selectable even when a provider uses
    # custom IDs absent from Codex's picker. Its origin is clearly labelled.
    configured = [preferred, settings.get('model')]
    ids = {model['id'] for model in models}
    for model_id in configured:
        if isinstance(model_id, str) and model_id.strip() and model_id not in ids:
            models.insert(0, {'id': model_id, 'name': model_id, 'effort': '', 'source': 'config'})
            ids.add(model_id)
    if not models:
        return {'ok': False, 'models': [], 'source': 'none', 'selected': '',
                'warning': '没有读取到模型，请检查本机 Codex 配置后点击刷新模型。'}
    if all(model['source'] == 'config' for model in models):
        source = 'config'
        warning = '没有读取到模型目录，当前仅显示本地配置中的模型。'
    return {'ok': True, 'models': models, 'source': source,
            'selected': preferred if preferred in ids else models[0]['id'], 'warning': warning}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--response', type=Path, required=True)
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text(encoding='utf-8-sig'))
        result = discover(config, args.config.resolve().parent)
    except Exception:
        result = {'ok': False, 'models': [], 'source': 'none', 'selected': '',
                  'warning': '无法读取本地模型配置，请检查配置文件。'}
    temporary = args.response.with_suffix('.tmp')
    temporary.write_text(json.dumps(result, ensure_ascii=False), encoding='utf-8')
    temporary.replace(args.response)


if __name__ == '__main__':
    main()
