"""Build a curated source ZIP. Never include local settings or runtime output."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
ROOT_FILES = (
    '.gitignore', 'README.md', 'AI_SETUP.md', 'LICENSE', 'VERSION', 'config.example.json',
    'start_ai.m', 'setup_cli.py', 'matlab_paths.py', 'bridge.py', 'launch_ui.py',
    'launch_ai.ps1', 'run_bridge.ps1', 'start_matlab.ps1', 'uninstall_integration.ps1',
    '启动MATLAB-AI.cmd',
)
DOC_FILES = (
    'docs/安装与使用.md', 'docs/功能参考.md', 'docs/开发与验证.md', 'docs/验证报告.md',
    'docs/github-launch.md', 'docs/release-notes.md', 'docs/images/setup-wizard.png',
)
SOURCE_DIRS = ('backend', 'matlab', 'examples', 'integration', 'tests', 'scripts')
SOURCE_SUFFIXES = {'.py', '.m', '.ps1', '.json', '.yml', '.md'}
FORBIDDEN_PARTS = {'output', 'dist', '.git', '__pycache__', '.pytest_cache', 'node_modules'}
SECRET_PATTERNS = (
    r'gh[pousr]_[A-Za-z0-9]{30,}', r'github_pat_[A-Za-z0-9_]{40,}',
    r'sk-(?:proj-)?[A-Za-z0-9_-]{32,}', r'-{5}BEGIN [A-Z ]*PRIVATE KEY-{5}',
)


def collect_files(root):
    paths = [root / name for name in ROOT_FILES + DOC_FILES]
    for folder in SOURCE_DIRS:
        paths.extend(p for p in (root/folder).rglob('*') if p.is_file()
                     and p.suffix in SOURCE_SUFFIXES
                     and not set(p.relative_to(root).parts) & FORBIDDEN_PARTS)
    result = {}
    for path in paths:
        relative = path.relative_to(root).as_posix()
        if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError('Missing or unsafe release file: ' + relative)
        if set(path.relative_to(root).parts) & FORBIDDEN_PARTS or path.name == 'config.local.json':
            raise ValueError('Private file in release: ' + relative)
        data = path.read_bytes()
        if path.suffix != '.png':
            text = data.decode('utf-8-sig')
            if any(re.search(pattern, text) for pattern in SECRET_PATTERNS):
                raise ValueError('Possible credential in release file: ' + relative)
        result[relative] = data
    return dict(sorted(result.items()))


def check_links(root, files):
    for name, data in files.items():
        if not name.endswith('.md'):
            continue
        text = data.decode('utf-8-sig')
        links = re.findall(r'!?\[[^\]]*\]\(([^)]+)\)', text)
        links += re.findall(r'<img[^>]+src="([^"]+)"', text)
        for link in links:
            if re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:', link) or link.startswith('#'):
                continue
            target = unquote(link.split('#')[0].strip('<>'))
            resolved = (root / name).parent.joinpath(target).resolve()
            if not resolved.is_relative_to(root.resolve()) or resolved.relative_to(root.resolve()).as_posix() not in files:
                raise ValueError('Unbundled documentation link: ' + name + ' -> ' + link)


def build(root, version, destination):
    if not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?', version):
        raise ValueError('Use a version such as v0.1.0-beta.1')
    if (root/'VERSION').read_text(encoding='utf-8-sig').strip() != version:
        raise ValueError('Version must match VERSION')
    files = collect_files(root)
    check_links(root, files)
    manifest = ''.join(hashlib.sha256(data).hexdigest() + '  ' + name + '\n' for name, data in files.items())
    files['MANIFEST.sha256'] = manifest.encode('utf-8')
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / ('matlab-ai-bridge-' + version + '.zip')
    temporary = archive.with_suffix('.zip.tmp')
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as package:
            for name, data in files.items():
                info = zipfile.ZipInfo('matlab-ai-bridge/' + name, date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                package.writestr(info, data)
        with zipfile.ZipFile(temporary) as package:
            if package.testzip() is not None:
                raise ValueError('ZIP validation failed')
        temporary.replace(archive)
    finally:
        temporary.unlink(missing_ok=True)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksum = archive.with_suffix('.zip.sha256')
    checksum.write_text(digest + '  ' + archive.name + '\n', encoding='utf-8')
    return {'zip': str(archive), 'sha256': digest, 'checksum': str(checksum),
            'files': len(files), 'bytes': archive.stat().st_size}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'dist')
    args = parser.parse_args()
    print(json.dumps(build(ROOT, args.version, args.output), ensure_ascii=True))
