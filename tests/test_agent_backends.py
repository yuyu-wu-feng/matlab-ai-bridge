import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import agent_backends as agents
import backend_config
import worker

FAKE = r'''
import json, sys, time
sys.stdin.reconfigure(encoding='utf-8')
sys.stdout.reconfigure(encoding='utf-8')
def send(x): print(json.dumps(x), flush=True)
mode=sys.argv[1]
answer={'explanation':'ok','replacement':'x=2;'}
if mode.startswith('claude'):
    sys.stdin.read()
    if mode=='claude_slow': time.sleep(1)
    if mode=='claude_tool':
        send({'type':'assistant','message':{'content':[{'type':'tool_use','name':'Edit'}]}})
    else:
        send({'type':'result','subtype':'success','structured_output':answer})
else:
    for line in sys.stdin:
        msg=json.loads(line)
        if msg['method']=='initialize':
            send({'id':1,'result':{'serverInfo':{'name':'deepseek-harness-sdk-runtime','version':'0.0.1'}}})
        else:
            sid=msg['params']['sessionId']
            if mode=='dsh_slow': time.sleep(1)
            def event(kind,data): send({'method':'session.event','params':{'sessionId':sid,'event':{'type':kind,'data':data}}})
            # Receipt can precede the RPC response.
            event('agent/inbox/spliced',{'inserted':[{'id':'message1'}]})
            send({'id':2,'result':{'messageId':'message1'}})
            event('assistant/message',{'message':{'content':[{'type':'text','text':json.dumps(answer)}]}})
            event('turn/end',{'reason':{'kind':'error' if mode=='dsh_error' else 'completed'}})
            send({'method':'session.status','params':{'sessionId':sid,'status':'idle'}})
'''


class BackendAdapterTests(unittest.TestCase):
    def run_fake(self, name, mode, cancel=False, **limits):
        with tempfile.TemporaryDirectory() as d:
            folder=Path(d)
            server=folder/'fake.py'; server.write_text(FAKE)
            request={'request_id':'test1','model':'test','question':'test','code':'','mode':'generate'}
            config={'backend':name,'timeout_seconds':4,'first_output_timeout_seconds':2,'idle_timeout_seconds':2,**limits}
            command=[sys.executable,'-u',str(server),mode]
            target='claude_command' if name=='claude' else 'executable_command'
            timer=threading.Timer(0.2,lambda: (folder/'cancel.flag').touch())
            if cancel: timer.start()
            try:
                with patch.object(agents,target,return_value=command):
                    return worker.run_request(request,config,folder,folder/'cancel.flag')
            finally:
                timer.cancel()
                if cancel: timer.join()

    def test_claude_and_dsh_normalized(self):
        for name,mode in [('claude','claude'),('deepseek_harness','dsh')]:
            with self.subTest(name=name):
                self.assertEqual(self.run_fake(name,mode)['replacement'],'x=2;')

    def test_tool_and_incomplete_dsh_rejected(self):
        with self.assertRaisesRegex(worker.RequestError,'工具'):
            self.run_fake('claude','claude_tool')
        with self.assertRaisesRegex(worker.RequestError,'未完整'):
            self.run_fake('deepseek_harness','dsh_error')

    def test_user_wait_time_controls_slow_backend(self):
        with self.assertRaisesRegex(worker.RequestError,'首次'):
            self.run_fake('claude','claude_slow',first_output_timeout_seconds=0.2)
        self.assertTrue(self.run_fake('claude','claude_slow',first_output_timeout_seconds=0)['ok'])

    def test_cancellation_for_both_adapters(self):
        for name,mode in [('claude','claude_slow'),('deepseek_harness','dsh_slow')]:
            with self.subTest(name=name), self.assertRaisesRegex(worker.RequestError,'取消'):
                self.run_fake(name,mode,cancel=True)

    def test_limits_reject_nan_and_inconsistent_values(self):
        for config in ({'timeout_seconds':float('nan')},{'timeout_seconds':0},
                       {'timeout_seconds':20,'first_output_timeout_seconds':30},
                       {'idle_timeout_seconds':-1}, {'timeout_seconds':True}):
            with self.assertRaises(ValueError): backend_config.validate_limits(config)
        self.assertEqual(backend_config.validate_limits({'first_output_timeout_seconds':0})['first_output_timeout_seconds'],0)

    def test_claude_tools_disabled_without_bare_auth_change(self):
        with patch.object(agents,'executable_command',return_value=['claude.exe']):
            cmd=agents.claude_command({})
        self.assertIn('--safe-mode',cmd)
        self.assertNotIn('--bare',cmd)
        self.assertEqual(cmd[cmd.index('--tools')+1],'')
        self.assertIn('--strict-mcp-config',cmd)

    def test_dsh_other_session_cannot_finish_request(self):
        state=agents.AgentEvents('deepseek_harness','owned')
        state.accept({'method':'session.status','params':{'sessionId':'other','status':'idle'}},worker.classify_error)
        self.assertFalse(state.done)

    def test_claude_structured_output_tool_is_allowed_but_edit_is_not(self):
        state=agents.AgentEvents('claude','owned')
        state.accept({'type':'system','subtype':'init','tools':['StructuredOutput'],'mcp_servers':[]},worker.classify_error)
        state.content([{'type':'tool_use','id':'schema1','name':'StructuredOutput'}])
        state.content([{'type':'tool_result','tool_use_id':'schema1','content':'ok'}])
        with self.assertRaises(worker.RequestError):
            state.content([{'type':'tool_use','name':'Edit'}])

    def test_request_rejected_for_unknown_backend(self):
        with self.assertRaises(ValueError): backend_config.backend_name({'backend':'typo'})

    def test_model_catalog_does_not_use_codex_for_other_agents(self):
        import model_catalog
        with patch.object(model_catalog,'read_rpc_models',side_effect=AssertionError('must not run')):
            result=model_catalog.discover({'backend':'claude','claude_executable':'nonexistent_xyz'},'.')
        self.assertEqual(result['selected'],'__default__')
        self.assertIn('未检测',result['warning'])


if __name__=='__main__': unittest.main()
