"""Install/remove an owned MATLAB startup block and a windowless desktop shortcut."""
from __future__ import annotations

import argparse
import ctypes
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BEGIN = '% >>> MATLAB_AI_ASSISTANT managed startup >>>'
END = '% <<< MATLAB_AI_ASSISTANT managed startup <<<'


def remove_block(data):
    if data.startswith(b'\xff\xfe'):
        encoding, bom = 'utf-16-le', b'\xff\xfe'
    elif data.startswith(b'\xfe\xff'):
        encoding, bom = 'utf-16-be', b'\xfe\xff'
    else:
        # Latin-1 gives a reversible 1:1 mapping for existing UTF-8/GBK bytes.
        encoding, bom = 'latin-1', b''
    text = data[len(bom):].decode(encoding)
    pattern = re.escape(BEGIN) + r'.*?' + re.escape(END) + r'(?:\r?\n)?'
    cleaned = re.sub(pattern, '', text, flags=re.DOTALL)
    return bom + cleaned.encode(encoding)


def add_block(data, root):
    clean = remove_block(data)
    matlab_path = str(root / 'matlab').replace("'", "''")
    block = (BEGIN + "\r\nif usejava('desktop')\r\n"
             + "    addpath('" + matlab_path + "');\r\n"
             + '    matlab_ai_startup;\r\nend\r\n' + END + '\r\n')
    if clean.startswith(b'\xff\xfe'):
        encoding, newline = 'utf-16-le', '\n'.encode('utf-16-le')
    elif clean.startswith(b'\xfe\xff'):
        encoding, newline = 'utf-16-be', '\n'.encode('utf-16-be')
    else:
        encoding, newline = 'utf-8', b'\n'
    if clean and not clean.endswith(newline):
        clean += '\r\n'.encode(encoding)
    return clean + block.encode(encoding)


def desktop_path():
    buffer = ctypes.create_unicode_buffer(32768)
    if ctypes.windll.shell32.SHGetFolderPathW(None, 0x10, None, 0, buffer):
        raise RuntimeError('Cannot resolve desktop folder')
    return Path(buffer.value)


def write_atomic(path, data):
    temporary = path.with_name(path.name + '.matlab-ai.tmp')
    temporary.write_bytes(data)
    temporary.replace(path)


def install():
    info = json.loads((ROOT / 'output/install-info.json').read_text(encoding='utf-8-sig'))
    if info.get('existing_startup'):
        startup = Path(info['existing_startup']).resolve()
        if startup.is_relative_to(Path(info['matlabroot']).resolve()):
            raise RuntimeError('Refusing to edit a startup file inside the MATLAB installation')
    else:
        startup = (Path(info['user_paths'][0]) / 'startup.m').resolve()
    if startup.name.lower() != 'startup.m':
        raise RuntimeError('Unexpected startup filename')
    shortcut = desktop_path() / 'MATLAB AI 助手.lnk'
    receipt_path = ROOT / 'output/integration.json'
    previous = json.loads(receipt_path.read_text(encoding='utf-8')) if receipt_path.exists() else {}
    startup.parent.mkdir(parents=True, exist_ok=True)
    existed = startup.exists()
    before = startup.read_bytes() if existed else b''
    backup = ROOT / 'output/integration-backups'
    backup.mkdir(exist_ok=True)
    if not previous:
        (backup / 'startup-original.bin').write_bytes(before)
        if shortcut.exists():
            shutil.copy2(shortcut, backup / 'shortcut-original.lnk')
        else:
            (backup / 'shortcut-original.lnk').unlink(missing_ok=True)
    write_atomic(startup, add_block(before, ROOT))
    try:
        # Use the installed PowerShell runtime and honor its execution policy.
        powershell = shutil.which('pwsh.exe') or shutil.which('powershell.exe')
        if not powershell:
            raise RuntimeError('PowerShell was not found')
        completed = subprocess.run([powershell, '-NoProfile', '-NonInteractive', '-File',
                        str(ROOT / 'integration/create_shortcut.ps1'),
                        '-ProjectRoot', str(ROOT), '-ShortcutPath', str(shortcut),
                        '-MatlabRoot', info['matlabroot']], capture_output=True,
                       creationflags=subprocess.CREATE_NO_WINDOW)
        if completed.returncode:
            # Shortcut diagnostics contain paths, not authentication data.
            diagnostic = completed.stderr.decode('utf-8', errors='replace')
            raise RuntimeError('Shortcut creation failed: ' + diagnostic[:2000])
    except Exception:
        if existed:
            write_atomic(startup, before)
        else:
            startup.unlink(missing_ok=True)
        raise
    receipt = {'ok': True, 'startup': str(startup), 'shortcut': str(shortcut),
               'startup_existed': previous.get('startup_existed', existed),
               'starts_with': 'MATLAB', 'uses_console': False}
    write_atomic(receipt_path, json.dumps(receipt, ensure_ascii=False, indent=2).encode('utf-8'))
    return receipt


def uninstall():
    receipt_path = ROOT / 'output/integration.json'
    receipt = json.loads(receipt_path.read_text(encoding='utf-8'))
    startup = Path(receipt['startup']).resolve()
    shortcut = Path(receipt['shortcut']).resolve()
    if startup.name.lower() != 'startup.m' or shortcut != (desktop_path() / 'MATLAB AI 助手.lnk').resolve():
        raise RuntimeError('Installation paths do not match the expected files')
    if startup.exists():
        clean = remove_block(startup.read_bytes())
        if not receipt['startup_existed'] and not clean.strip():
            startup.unlink()
        else:
            write_atomic(startup, clean)
    original_shortcut = ROOT / 'output/integration-backups/shortcut-original.lnk'
    if original_shortcut.exists():
        shutil.copy2(original_shortcut, shortcut)
    else:
        shortcut.unlink(missing_ok=True)
    receipt_path.unlink()
    return {'ok': True, 'message': 'Removed MATLAB startup entry and desktop shortcut.'}


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser()
    parser.add_argument('--uninstall', action='store_true')
    args = parser.parse_args()
    print(json.dumps(uninstall() if args.uninstall else install(), ensure_ascii=False, indent=2))
