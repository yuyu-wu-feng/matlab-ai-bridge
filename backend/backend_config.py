"""Backend-neutral settings. No credential discovery or model requests."""
import math
from pathlib import Path
import shutil

BACKENDS = ('codex', 'claude', 'deepseek_harness')
DEFAULT_LIMITS = {'timeout_seconds': 60, 'first_output_timeout_seconds': 25,
                  'idle_timeout_seconds': 20}


def validate_limits(config):
    limits = {}
    for key, default in DEFAULT_LIMITS.items():
        value = config.get(key, default)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError('等待时间必须是有限数字（秒）。')
        minimum = 0.01 if key == 'timeout_seconds' else 0
        if not minimum <= value <= 86400:
            raise ValueError('总等待需大于 0；首次和中断等待为 0–86400 秒，0 表示关闭该限制。')
        limits[key] = value
    # Explicit settings must be coherent; legacy callers can supply only total.
    if any(k in config and limits[k] > limits['timeout_seconds'] for k in
           ('first_output_timeout_seconds', 'idle_timeout_seconds')):
        raise ValueError('总等待时间不能小于首次回答或回答中断等待时间。')
    return limits


def backend_name(config):
    name = config.get('backend', 'codex')
    if name not in BACKENDS:
        raise ValueError('不支持此 Agent，请选择 Codex、Claude Code 或 DeepSeek Harness。')
    return name


def executable_command(config, name):
    """Use argv only; do not run .cmd wrappers through a shell."""
    value = config.get(name + '_executable') or {'codex': 'codex', 'claude': 'claude',
                                               'deepseek_harness': 'dsh'}[name]
    resolved = shutil.which(value) or (str(Path(value)) if Path(value).is_file() else None)
    if not resolved:
        raise ValueError('未找到 Agent 程序，请在“后端与等待设置”中填写程序路径。')
    path = Path(resolved)
    if path.suffix.lower() in ('.cmd', '.bat', '.ps1'):
        if name == 'codex':
            entry = path.parent / 'node_modules/@openai/codex/bin/codex.js'
            node = shutil.which(config.get('node_executable') or 'node')
            if entry.is_file() and node:
                return [node, str(entry)]
        if name == 'claude':
            native = path.parent / 'node_modules/@anthropic-ai/claude-code/bin/claude.exe'
            if native.is_file():
                return [str(native)]
        raise ValueError('请填写 Agent 原生可执行文件或 CLI 的 .js 入口，不使用 .cmd/.ps1 包装脚本。')
    if path.suffix.lower() in ('.js', '.mjs', '.cjs'):
        node = shutil.which(config.get('node_executable') or 'node')
        if not node:
            raise ValueError('此 Agent 的 JavaScript 入口需要 Node.js。')
        return [node, str(path)]
    return [str(path)]
