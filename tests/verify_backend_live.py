"""Opt-in real request, isolated from MATLAB drafts and saved settings."""
import argparse
import json
from pathlib import Path
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'backend'))
import worker

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('backend',choices=['codex','claude','deepseek_harness'])
    parser.add_argument('--executable')
    parser.add_argument('--model')
    args=parser.parse_args()
    config=json.loads((ROOT/'config.local.json').read_text(encoding='utf-8-sig'))
    config.update(backend=args.backend,timeout_seconds=180,first_output_timeout_seconds=120,idle_timeout_seconds=90)
    if args.executable: config[args.backend+'_executable']=args.executable
    model=args.model or ('__default__' if args.backend=='claude' else config['model'])
    request=dict(request_id='live_'+args.backend,question='Generate MATLAB code that assigns 2 to x, then assigns x squared to y.',
                 code='',mode='generate',model=model,stream=True)
    started=time.monotonic()
    try:
        with tempfile.TemporaryDirectory(prefix='live-',dir=ROOT/'output') as directory:
            folder=Path(directory)
            result=worker.run_request(request,config,folder,folder/'cancel.flag')
        report=dict(ok=True,backend=args.backend,elapsed_seconds=round(time.monotonic()-started,2),
                    has_code=bool(result.get('replacement')),chunks=result.get('stream_chunks',0))
    except worker.RequestError as e:
        report=dict(ok=False,backend=args.backend,error=str(e))
    (ROOT/'output'/('test-live-'+args.backend+'.json')).write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(report,ensure_ascii=True))
    return 0 if report['ok'] else 1

if __name__=='__main__': sys.exit(main())
