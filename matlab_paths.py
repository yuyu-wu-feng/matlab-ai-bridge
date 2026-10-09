"""Locate MATLAB for optional external launchers; the in-MATLAB entry needs none."""
import os
from pathlib import Path
import shutil


def resolve_matlab_root(explicit=None):
    candidates = []
    if explicit:
        candidates.append(Path(explicit))
    elif os.environ.get('MATLAB_ROOT'):
        candidates.append(Path(os.environ['MATLAB_ROOT']))
    else:
        command = shutil.which('matlab')
        if command:
            candidates.append(Path(command).resolve().parent.parent)
        if os.name == 'nt':
            import winreg
            try:
                with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\MathWorks\MATLAB') as key:
                    versions = []
                    for i in range(winreg.QueryInfoKey(key)[0]):
                        versions.append(winreg.EnumKey(key, i))
                    for version in sorted(versions, reverse=True):
                        try:
                            with winreg.OpenKey(key, version) as child:
                                candidates.append(Path(winreg.QueryValueEx(child, 'MATLABROOT')[0]))
                        except OSError:
                            pass
            except OSError:
                pass
        base = Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / 'MATLAB'
        candidates.extend(sorted(base.glob('R*'), reverse=True))
    for root in candidates:
        if (root / 'bin/matlab.exe').is_file() or (root / 'bin/matlab').is_file():
            return root
    raise ValueError('找不到 MATLAB。请传入 --matlab-root 安装目录，或直接在 MATLAB 中运行 start_ai.m。')
