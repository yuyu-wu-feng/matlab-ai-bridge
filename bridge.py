"""Connect to an explicitly named, already running local MATLAB session."""
import argparse
import json
from pathlib import Path
import sys
from matlab_paths import resolve_matlab_root


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['discover', 'status', 'probe', 'app', 'test', 'test-local', 'demo', 'ui-status', 'upgrade-ui', 'test-models', 'install-info', 'test-generate', 'test-workflow', 'test-workflow-local', 'test-responsiveness', 'test-help', 'test-help-local', 'simulink-status', 'test-simulink', 'test-simulink-local'])
    parser.add_argument('--matlab-root', help='MATLAB installation root; otherwise detect locally')
    parser.add_argument('--session', default='MATLAB_AI_BRIDGE')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    engine_dist = resolve_matlab_root(args.matlab_root) / 'extern/engines/python/dist'
    sys.path.insert(0, str(engine_dist))
    import matlab.engine
    sessions = matlab.engine.find_matlab()
    if args.command == 'discover':
        print(json.dumps({'sessions': sessions}, ensure_ascii=False))
        return 0
    if args.session not in sessions:
        raise RuntimeError(f'Session {args.session!r} not found. Run start_matlab.ps1 first.')
    # Specifying the session prevents accidental creation/selection of another MATLAB.
    engine = matlab.engine.connect_matlab(args.session, background=True).result(timeout=60)
    if args.command == 'status':
        report = json.loads(engine.bridge_status())
    elif args.command == 'simulink-status':
        report = json.loads(engine.ai_simulink_probe())
    elif args.command in ('test-simulink', 'test-simulink-local'):
        report = json.loads(engine.ai_simulink_test(args.command == 'test-simulink'))
    elif args.command == 'probe':
        report = json.loads(engine.bridge_probe(str(root / 'output')))
    elif args.command in ('test', 'test-local'):
        report = json.loads(engine.ai_selftest(args.command == 'test'))
    elif args.command == 'demo':
        report = json.loads(engine.ai_demo())
    elif args.command == 'ui-status':
        report = json.loads(engine.ai_ui_status())
    elif args.command == 'upgrade-ui':
        report = json.loads(engine.ai_upgrade_ui())
    elif args.command == 'test-models':
        report = json.loads(engine.ai_model_picker_test())
    elif args.command == 'install-info':
        report = json.loads(engine.ai_install_info())
    elif args.command == 'test-generate':
        report = json.loads(engine.ai_generate_test())
    elif args.command == 'test-responsiveness':
        report = json.loads(engine.ai_responsiveness_test())
    elif args.command in ('test-help', 'test-help-local'):
        report = json.loads(engine.ai_help_test(args.command == 'test-help'))
    elif args.command in ('test-workflow', 'test-workflow-local'):
        report = json.loads(engine.ai_workflow_test(args.command == 'test-workflow'))
    else:
        engine.matlab_ai(nargout=0)
        report = {'ok': True, 'message': 'MATLAB AI assistant window opened'}
    output = root / 'output'
    output.mkdir(exist_ok=True)
    (output / f'{args.command}.json').write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2))
    # Do not quit the user's MATLAB. Shared-session disconnect occurs on exit.
    return 0 if report.get('ok', True) else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(f'{type(error).__name__}: {error}', file=sys.stderr)
        sys.exit(1)
