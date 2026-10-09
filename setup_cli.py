"""First-run setup shared by the MATLAB wizard and external coding assistants.

discover/check never call models. check --live is an explicit model request.
All commands print a JSON report; credentials and model output are excluded.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'backend'))


def run_version(command):
    from worker import stop_process
    with subprocess.Popen(command + ['--version'], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding='utf-8', errors='replace',
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0) as process:
        try:
            stdout, stderr = process.communicate(timeout=6)
        finally:
            stop_process(process)
    match = re.search(r'\b\d+\.\d+(?:\.\d+)?(?:[-+][A-Za-z0-9.-]+)?', stdout + stderr)
    if process.returncode or not match:
        raise ValueError('程序版本检查失败，请检查程序路径和安装情况。')
    return match.group(0)


def agent_candidates(name):
    command = {'codex': 'codex', 'claude': 'claude', 'deepseek_harness': 'dsh'}[name]
    found = shutil.which(command)
    if found:
        yield found
    home = Path.home()
    for base in (home / '.local/bin', home / '.cargo/bin'):
        for suffix in ('.exe', ''):
            path = base / (command + suffix)
            if path.is_file():
                yield str(path)
    npm = Path(os.environ.get('APPDATA', str(home / 'AppData/Roaming'))) / 'npm'
    if name == 'claude':
        path = npm / 'node_modules/@anthropic-ai/claude-code/bin/claude.exe'
        if path.is_file():
            yield str(path)
    if name == 'codex':
        base = npm / 'node_modules/@openai'
        for path in base.glob('codex*/**/bin/codex.exe'):
            yield str(path)
    for suffix in ('.exe', '.cmd'):
        path = npm / (command + suffix)
        if path.is_file():
            yield str(path)


def inspect_agent(name, explicit='', node=''):
    from backend_config import executable_command
    candidates = [explicit] if explicit else list(dict.fromkeys(agent_candidates(name)))
    for candidate in candidates:
        try:
            command = executable_command({name + '_executable': candidate, 'node_executable': node}, name)
            version = run_version(command)
            return {'backend': name, 'available': True, 'executable': command[-1],
                    'node_executable': command[0] if len(command) > 1 else '', 'version': version,
                    'message': '程序可启动；尚未验证登录和模型调用。'}
        except (OSError, ValueError, subprocess.TimeoutExpired):
            continue
    return {'backend': name, 'available': False, 'executable': explicit, 'node_executable': node,
            'version': '', 'message': '未检测到可用程序，请安装后重新检测或手动选择程序文件。'}


def suggested_model(name):
    if name == 'claude':
        return ''
    if name == 'codex':
        import tomllib
        home = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))
        try:
            model = tomllib.loads((home / 'config.toml').read_text(encoding='utf-8-sig')).get('model', '')
            if isinstance(model, str) and len(model) <= 200 and not any(ord(c) < 32 for c in model):
                return model
        except (OSError, ValueError):
            pass
    return ''


def discover():
    from backend_config import BACKENDS
    agents = [inspect_agent(name) for name in BACKENDS]
    for agent in agents:
        agent['suggested_model'] = suggested_model(agent['backend'])
    return {'ok': True, 'stage': 'discovery', 'python_executable': sys.executable,
            'python_version': '.'.join(map(str, sys.version_info[:3])), 'agents': agents,
            'model_called': False}


def read_config(path):
    if not path.exists():
        return {}, None
    raw = path.read_bytes()
    try:
        value = json.loads(raw.decode('utf-8-sig'))
        if not isinstance(value, dict):
            raise ValueError
    except (ValueError, UnicodeError):
        raise ValueError('配置不是有效 JSON 对象。请先备份并修复原文件，向导不会覆盖损坏文件。') from None
    return value, raw


def configure(args):
    from backend_config import validate_limits
    previous, original = read_config(args.config)
    if original is not None and not args.overwrite:
        raise ValueError('配置已存在。保留现有配置；需要更新时显式添加 --overwrite。')
    agent = inspect_agent(args.backend, args.agent, args.node)
    if not agent['available']:
        raise ValueError(agent['message'])
    model = args.model.strip()
    if not model:
        model = suggested_model(args.backend)
    if args.backend == 'claude' and not model:
        model = '__default__'
    if not model or len(model) > 200 or any(ord(c) < 32 for c in model):
        raise ValueError('请填写有效模型 ID；Claude 可留空使用默认模型。')
    config = dict(previous)
    config.update(backend=args.backend, model=model, python_executable=sys.executable,
                  timeout_seconds=args.total, first_output_timeout_seconds=args.first,
                  idle_timeout_seconds=args.idle, setup_version=1)
    config[args.backend + '_executable'] = agent['executable']
    if agent['node_executable']:
        config['node_executable'] = agent['node_executable']
    config.update(validate_limits(config))
    models = dict(config.get('backend_models', {}))
    if previous.get('model'):
        models[previous.get('backend', 'codex')] = previous['model']
    models[args.backend] = model
    config['backend_models'] = models
    for name in ('codex', 'claude', 'deepseek_harness'):
        config.setdefault(name + '_executable', '')
    payload = json.dumps(config, ensure_ascii=False, indent=2) + '\n'
    args.config.parent.mkdir(parents=True, exist_ok=True)
    backup = None
    if original is None:
        # Publish only a complete file, without replacing a concurrent creator.
        temp = args.config.with_name(args.config.name + '.' + uuid.uuid4().hex + '.tmp')
        try:
            temp.write_text(payload, encoding='utf-8')
            if os.name == 'nt':
                temp.rename(args.config)  # Windows rename fails if destination exists.
            else:
                os.link(temp, args.config)
        finally:
            temp.unlink(missing_ok=True)
    else:
        if args.config.read_bytes() != original:
            raise ValueError('配置已被其他窗口更新，请重新打开向导。')
        backup_dir = args.config.parent / 'output/setup-backups'
        backup_dir.mkdir(parents=True, exist_ok=True)
        backup = backup_dir / (uuid.uuid4().hex + '.json')
        backup.write_bytes(original)
        temp = args.config.with_name(args.config.name + '.' + uuid.uuid4().hex + '.tmp')
        try:
            temp.write_text(payload, encoding='utf-8')
            temp.replace(args.config)
        finally:
            temp.unlink(missing_ok=True)
    return {'ok': True, 'stage': 'configured', 'config_path': str(args.config.resolve()),
            'backend': args.backend, 'model': model, 'model_called': False,
            'backup_path': str(backup) if backup else None,
            'message': '配置已保存。尚未验证登录、额度或真实模型调用。'}


def check(args):
    from backend_config import backend_name, validate_limits
    config, _ = read_config(args.config)
    if not config:
        raise ValueError('未找到配置，请先运行 configure 或 MATLAB 配置向导。')
    name = backend_name(config)
    validate_limits(config)
    python = config.get('python_executable', '')
    if not Path(python).is_file():
        raise ValueError('配置中的 Python 文件不存在，请重新运行向导。')
    version = run_version([python])
    if tuple(map(int, version.split('.')[:2])) < (3, 11):
        raise ValueError('需要 Python 3.11 或更高版本。')
    agent = inspect_agent(name, config.get(name + '_executable', ''), config.get('node_executable', ''))
    if not agent['available']:
        raise ValueError(agent['message'])
    report = {'ok': True, 'stage': 'installation_checked', 'backend': name,
              'version': agent['version'], 'model_called': False,
              'message': '安装检查通过；尚未验证登录或模型连接。'}
    if args.live:
        if not Path(python).samefile(sys.executable):
            raise ValueError('真实连接测试请使用配置中的 python_executable 运行 setup_cli.py check --live。')
        import worker
        model = config.get('model', '')
        if not model:
            raise ValueError('配置缺少模型 ID，请先完成配置。')
        report.update(stage='model_checked', model_called=True)
        output = args.config.parent / 'output'
        output.mkdir(exist_ok=True)
        try:
            with tempfile.TemporaryDirectory(prefix='setup-check-', dir=output) as folder:
                work = Path(folder)
                request = dict(request_id='setup_' + uuid.uuid4().hex, question='Explain disp(1) in one sentence.',
                               code='disp(1)', mode='explain', model=model, stream=True)
                worker.run_request(request, config, work, work / 'cancel.flag')
            report['message'] = '真实模型连接成功，响应格式校验通过；未读取或修改用户文档。'
        except worker.RequestError as error:
            report.update(ok=False, message=str(error))
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    d = sub.add_parser('discover', help='Detect installed programs; no model calls')
    c = sub.add_parser('configure', help='Write project config after installation checks')
    k = sub.add_parser('check', help='Check install; --live explicitly calls a model')
    for cmd in (d, c, k):
        cmd.add_argument('--output', type=Path, help='Also write the same JSON report here')
    for cmd in (c, k):
        cmd.add_argument('--config', type=Path, default=ROOT / 'config.local.json')
    c.add_argument('--backend', choices=['codex', 'claude', 'deepseek_harness'], required=True)
    c.add_argument('--agent', default='', help='Native executable or JavaScript entry; blank discovers')
    c.add_argument('--node', default='')
    c.add_argument('--model', default='')
    c.add_argument('--first', type=float, default=120)
    c.add_argument('--idle', type=float, default=90)
    c.add_argument('--total', type=float, default=600)
    c.add_argument('--overwrite', action='store_true')
    k.add_argument('--live', action='store_true', help='May consume model quota; uses only a fixed tiny example')
    args = parser.parse_args(argv)
    try:
        if sys.version_info < (3, 11):
            raise ValueError('需要 Python 3.11 或更高版本。')
        report = {'discover': discover, 'configure': lambda: configure(args), 'check': lambda: check(args)}[args.command]()
    except (ValueError, FileExistsError) as error:
        report = {'ok': False, 'stage': args.command, 'message': str(error), 'model_called': False}
    except Exception:
        report = {'ok': False, 'stage': args.command, 'message': '配置操作失败，请检查路径、权限和程序安装；未输出原始异常。'}
    payload = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(payload, encoding='utf-8')
    print(json.dumps(report, ensure_ascii=True))
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
