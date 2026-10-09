"""Open the assistant in its shared MATLAB, or start one when needed."""
import argparse
from pathlib import Path
import subprocess
import sys
import time
from matlab_paths import resolve_matlab_root


def main():
    if sys.stdout is not None:
        sys.stdout.reconfigure(encoding='utf-8')
    if sys.stderr is not None:
        sys.stderr.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser()
    parser.add_argument('--matlab-root', help='MATLAB installation root; otherwise detect locally')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    matlab_root = resolve_matlab_root(args.matlab_root)
    sys.path.insert(0, str(matlab_root / 'extern/engines/python/dist'))
    import matlab.engine
    name = 'MATLAB_AI_BRIDGE'
    if name not in matlab.engine.find_matlab():
        bootstrap = str(root / 'matlab/bridge_bootstrap.m').replace("'", "''")
        (root / 'output').mkdir(exist_ok=True)
        subprocess.Popen([str(matlab_root / 'bin/matlab.exe'), '-desktop', '-sd', str(root),
                          '-logfile', str(root / 'output/matlab-startup.log'),
                          '-r', f"run('{bootstrap}')"], creationflags=subprocess.CREATE_NO_WINDOW)
        start = time.monotonic()
        while name not in matlab.engine.find_matlab():
            if time.monotonic() - start > 150:
                raise RuntimeError('MATLAB 启动超时，请检查许可证或启动窗口。')
            time.sleep(1)
    engine = matlab.engine.connect_matlab(name, background=True).result(timeout=60)
    engine.addpath(str(root / 'matlab'), nargout=0)
    engine.matlab_ai(nargout=0)
    if sys.stdout is not None:
        print('MATLAB AI 助手已打开。')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        if sys.stderr is not None:
            print(str(error), file=sys.stderr)
        else:
            import ctypes
            ctypes.windll.user32.MessageBoxW(None, str(error), 'MATLAB AI 助手启动失败', 0x10)
        sys.exit(1)
