import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import setup_cli as setup


class SetupTests(unittest.TestCase):
    def args(self, folder, **changes):
        return argparse.Namespace(**(dict(config=Path(folder)/'config.local.json', backend='claude',
            agent='', node='', model='', first=120, idle=90, total=600, overwrite=False, live=False) | changes))

    def agent(self, *args):
        return dict(available=True, executable=sys.executable, node_executable='', version='1.2.3')

    @patch.object(setup, 'inspect_agent')
    def test_discovery_no_config_and_no_model(self, inspect):
        inspect.side_effect=lambda name: dict(backend=name,available=False)
        with patch.object(setup,'suggested_model',return_value=''):
            result=setup.discover()
        self.assertTrue(result['ok']); self.assertFalse(result['model_called'])
        self.assertEqual(len(result['agents']),3)

    def test_configure_default_and_no_clobber(self):
        with tempfile.TemporaryDirectory() as d, patch.object(setup,'inspect_agent',side_effect=self.agent):
            args=self.args(d); report=setup.configure(args)
            self.assertFalse(report['model_called'])
            config=json.loads(args.config.read_text(encoding='utf-8'))
            self.assertEqual(config['model'],'__default__')
            self.assertEqual(config['python_executable'],sys.executable)
            before=args.config.read_bytes()
            with self.assertRaises(ValueError): setup.configure(args)
            self.assertEqual(before,args.config.read_bytes())

    def test_overwrite_backs_up_preserves_fields_and_models(self):
        with tempfile.TemporaryDirectory() as d, patch.object(setup,'inspect_agent',side_effect=self.agent):
            args=self.args(d,overwrite=True)
            original={'backend':'codex','model':'old-model','custom':{'keep':True},'backend_models':{}}
            args.config.write_text(json.dumps(original),encoding='utf-8')
            report=setup.configure(args)
            config=json.loads(args.config.read_text(encoding='utf-8'))
            self.assertEqual(config['custom'],original['custom'])
            self.assertEqual(config['backend_models']['codex'],'old-model')
            self.assertEqual(json.loads(Path(report['backup_path']).read_text()),original)

    def test_invalid_limits_never_write(self):
        with tempfile.TemporaryDirectory() as d, patch.object(setup,'inspect_agent',side_effect=self.agent):
            for total in (10,float('nan'),-1):
                args=self.args(d,total=total)
                with self.assertRaises(ValueError): setup.configure(args)
                self.assertFalse(args.config.exists())

    def test_corrupt_config_not_overwritten(self):
        with tempfile.TemporaryDirectory() as d:
            args=self.args(d,overwrite=True); args.config.write_text('{broken')
            with self.assertRaises(ValueError): setup.configure(args)
            self.assertEqual(args.config.read_text(),'{broken')

    def test_no_agent_does_not_write(self):
        with tempfile.TemporaryDirectory() as d, patch.object(setup,'inspect_agent',return_value={'available':False,'message':'missing'}):
            args=self.args(d)
            with self.assertRaisesRegex(ValueError,'missing'): setup.configure(args)
            self.assertFalse(args.config.exists())

    def test_codex_model_is_required_without_suggestion(self):
        with tempfile.TemporaryDirectory() as d, patch.object(setup,'inspect_agent',side_effect=self.agent), patch.object(setup,'suggested_model',return_value=''):
            args=self.args(d,backend='codex')
            with self.assertRaises(ValueError): setup.configure(args)
            self.assertFalse(args.config.exists())

    def test_installation_check_never_calls_model(self):
        with tempfile.TemporaryDirectory() as d, patch.object(setup,'inspect_agent',side_effect=self.agent), patch.object(setup,'run_version',return_value='3.12.0'), patch('worker.run_request') as request:
            args=self.args(d); setup.configure(args)
            result=setup.check(args)
            self.assertTrue(result['ok']); self.assertFalse(result['model_called']); request.assert_not_called()

    def test_live_check_uses_fixed_example_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as d, patch.object(setup,'inspect_agent',side_effect=self.agent), patch.object(setup,'run_version',return_value='3.12.0'), patch('worker.run_request',return_value={'ok':True}) as request:
            args=self.args(d,live=True); setup.configure(args)
            result=setup.check(args)
            self.assertTrue(result['model_called'])
            self.assertEqual(request.call_args.args[0]['code'],'disp(1)')
            self.assertEqual(list((Path(d)/'output').glob('setup-check-*')),[])

    def test_machine_json_failure_and_no_raw_exception(self):
        with patch.object(setup,'discover',side_effect=RuntimeError('SECRET_TOKEN')), contextlib.redirect_stdout(io.StringIO()) as out:
            code=setup.main(['discover'])
        self.assertEqual(code,1); self.assertFalse(json.loads(out.getvalue())['ok'])
        self.assertNotIn('SECRET_TOKEN',out.getvalue())

    def test_suggestion_reads_only_model(self):
        with tempfile.TemporaryDirectory() as d, patch.dict(os.environ,{'CODEX_HOME':d}):
            (Path(d)/'config.toml').write_text('model="test-model"\napi_key="SECRET"',encoding='utf-8')
            self.assertEqual(setup.suggested_model('codex'),'test-model')

    def test_js_entry_normalized_in_codex_request(self):
        import worker
        with tempfile.TemporaryDirectory() as d, patch.dict(os.environ,{'CODEX_HOME':d}), patch('backend_config.executable_command',return_value=['node.exe','codex.js']):
            command=worker.codex_command({'codex_executable':'codex.js'}, {'model':'test'}, Path(d), Path(d)/'out.json')
            self.assertEqual(command[0][:2],['node.exe','codex.js'])

    def test_js_entry_normalized_in_catalog(self):
        import model_catalog
        with tempfile.TemporaryDirectory() as d, patch('backend_config.executable_command',return_value=['node.exe','codex.js']), patch.object(model_catalog,'read_rpc_models',return_value=[{'model':'test'}]) as read:
            report=model_catalog.discover({'codex_executable':'codex.js','model':'test'},d,d)
            self.assertEqual(read.call_args.args[0],['node.exe','codex.js'])
            self.assertEqual(report['source'],'codex')


if __name__=='__main__': unittest.main()
