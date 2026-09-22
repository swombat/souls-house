"""Offline consent-policy tests. No real residents, credentials or model calls."""
import concurrent.futures
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'agent-runtime'))
import resident_memory_policy as policy
import stop_journal_reflex as stop
os.environ.setdefault("TRIGGER_BEARER_TOKEN", "offline-test")
import trigger_shim as shim


class MemoryPolicyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.identity = Path(self.tmp.name)
        self.path = self.identity / policy.POLICY_FILE
        self.path.parent.mkdir()
        self.config = dict(version=1, enabled=True, journal='ordinary-significance-v1',
                           consolidation='source-bound-v1', graph='address-per-entry', ladder=policy.LADDER)
        self.write()

    def write(self):
        self.path.write_text(json.dumps(self.config))

    def payload(self, period='daily', target='2026-09-21'):
        return dict(trigger_kind='memory_aggregation_'+period,
                    memory_aggregation=dict(period=period, target=target, notices='HOUSE NOTICE'),
                    session_id='test-session', request='LEGACY REQUEST')

    def test_policy_is_opt_in_and_revocable(self):
        self.assertIsNotNone(policy.load_policy(self.identity))
        self.config['enabled'] = False
        self.write()
        self.assertIsNone(policy.load_policy(self.identity))
        self.assertIsNone(policy.aggregation_request(self.payload(), self.identity))
        self.path.unlink()
        self.assertIsNone(policy.load_policy(self.identity))
        for raw in ['{broken', '[]', '{"enabled": true}', 'null']:
            self.path.write_text(raw)
            self.assertIsNone(policy.load_policy(self.identity))

    def test_exact_ladder_and_valid_metadata(self):
        for period, target, source, dest in [
            ('daily','2026-09-21','daily-journals/2026-09-21.md','weekly-journals/2026-09-21.md'),
            ('weekly','2026-08-31','weekly-journals/2026-08-31.md','monthly-journals/2026-08.md'),
            ('monthly','2026-09','monthly-journals/2026-09.md','yearly-journals/2026.md')]:
            text = policy.aggregation_request(self.payload(period,target), self.identity)
            for value in [source,dest,'HOUSE NOTICE','missing evidence','leave it unchanged','not a template','self-narrative untouched']:
                self.assertIn(value,text)
        for period,target in [('daily','2026-02-30'),('weekly','2026-09-22'),('daily','../../x'),('monthly','2026-13')]:
            self.assertIsNone(policy.aggregation_context(self.payload(period,target)))
        data = self.payload();data['trigger_kind']='telegram'
        self.assertIsNone(policy.aggregation_context(data))
        self.assertIsNone(policy.aggregation_context({'request':'memory_aggregation_daily'}))

    def run_stop(self, written=(), aggregation=False, assistant='Completed work', active=False):
        out=io.StringIO()
        trace=[]
        env={'SOULSHOUSE_MEMORY_AGGREGATION':'1' if aggregation else ''}
        with patch.object(stop,'IDENTITY_PATH',self.identity), patch.object(stop,'entries_since',return_value=written), patch.object(stop,'turn_floor',return_value=None), patch.object(stop,'append_trace',side_effect=lambda e,a,i:trace.append(i)), patch.object(stop,'command_reference',return_value=(ROOT/'agent-runtime/docs/memory-quick-reference.md').read_text()), patch.dict(os.environ,env), patch('sys.stdin',io.StringIO(json.dumps(dict(last_assistant_message=assistant,stop_hook_active=active)))), contextlib.redirect_stderr(out):
            try:stop.main();code=0
            except SystemExit as e:code=e.code
        return code,out.getvalue(),trace

    def test_ordinary_invitation_and_wing_address_rule(self):
        code,text,trace=self.run_stop()
        self.assertEqual(code,2);self.assertEqual(trace,[True])
        self.assertIn('whole completed exchange',text)
        self.assertIn('For each authored entry',text)
        self.assertNotIn('What did this feel like from inside',text)
        self.assertNotIn('If you journaled, index it',text)
        code,text,_=self.run_stop(written=[('09:00','Already authored')])
        self.assertEqual(code,2);self.assertIn('Do not write them again',text)

    def test_grok_no_second_address_invitation(self):
        self.config['graph']='selective';self.write()
        for assistant in ['Work completed','journaled: Already authored']:
            code,text,trace=self.run_stop(written=[('09:00','Already authored')],assistant=assistant)
            self.assertEqual((code,text,trace),(0,'',[False]))
        code,text,_=self.run_stop()
        self.assertEqual(code,2)
        self.assertIn('zero, one or several',text)
        self.assertNotIn('Then save its short handle',text)
        self.assertNotIn('only its address is missing',text)

    def test_aggregation_suppressed_but_non_opted_in_unchanged(self):
        self.assertEqual(self.run_stop(aggregation=True),(0,'',[False]))
        self.config['enabled']=False;self.write()
        code,text,_=self.run_stop(aggregation=True)
        self.assertEqual(code,2);self.assertIn('What did this feel like from inside',text)
        self.assertNotIn('Resident-consented',text)
        for kwargs in [dict(active=True),dict(assistant='no shape'),dict(assistant='')]:
            self.assertEqual(self.run_stop(**kwargs),(0,'',[False]))

    def test_no_authored_files_changed_by_hook(self):
        daily=self.identity/'memory/daily-journals/2026-09-22.md';daily.parent.mkdir(parents=True);daily.write_text('CANONICAL SOURCE')
        before=daily.read_bytes();self.run_stop();self.run_stop(aggregation=True)
        self.assertEqual(daily.read_bytes(),before)

    def test_fresh_and_resumed_runtime_reference_and_opt_out(self):
        with patch.object(shim,'AGENT_IDENTITY_PATH',self.identity), patch.object(shim,'AGENT_RUNTIME_DOCS_PATH',ROOT/'agent-runtime/docs'):
            self.config['graph']='selective';self.write()
            for text in [shim.build_prompt('REQUEST'),shim.memory_command_reference()]:
                self.assertIn('zero, one or several',text)
                self.assertNotIn('If you journaled, index it',text)
                self.assertNotIn('Then save its short handle',text)
                self.assertNotIn('respond exactly `no shape`',text)
                self.assertIn('not a journal invitation',text)
            self.config['enabled']=False;self.write()
            self.assertIn('If you journaled, index it',shim.build_prompt('REQUEST'))
            self.assertIn('Then save its short handle',shim.memory_command_reference())

    def test_fresh_resume_and_concurrent_execution_environments(self):
        barrier=threading.Barrier(4)
        captures=[]
        def fake_run(args,**kwargs):
            captures.append((list(args),dict(kwargs['env'])))
            return subprocess.CompletedProcess(args,0,'','')
        def call(index):
            shim._activity_context.memory_aggregation=index%2==0
            shim._activity_context.reporter=None
            barrier.wait()
            shim.run_chaos('test',5,'prompt',True,resume_id='prior' if index>=2 else None)
            shim._activity_context.memory_aggregation=False
        with patch.object(shim.subprocess,'run',side_effect=fake_run), patch.dict(os.environ,{'SOULSHOUSE_MEMORY_AGGREGATION':'stale'}):
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(call,range(4)))
        for resumed in [False,True]:
            flags=[env.get('SOULSHOUSE_MEMORY_AGGREGATION') for args,env in captures if ('resume' in args)==resumed]
            self.assertCountEqual(flags,['1',None])

    def test_before_turn_reference_obeys_selective_policy_without_model_call(self):
        self.config['graph']='selective';self.write()
        env=dict(os.environ, AGENT_IDENTITY_PATH=str(self.identity), AGENT_RUNTIME_DOCS_PATH=str(ROOT/'agent-runtime/docs'))
        result=subprocess.run([sys.executable,str(ROOT/'agent-runtime/memory_before_turn.py')],input=json.dumps({'input':'<mnemodyne-preview-attempted/>'}),text=True,capture_output=True,env=env)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('zero, one or several',result.stdout)
        self.assertNotIn('Then save its short handle',result.stdout)
        self.assertNotIn('mnemodyne_preview=',result.stderr)

    def test_policy_error_releases_trigger_lock_and_context(self):
        from types import SimpleNamespace
        request=SimpleNamespace(headers={'Authorization':'Bearer test'},get_json=lambda **_:self.payload())
        with patch.object(shim,'request',request), patch.object(shim,'TRIGGER_BEARER_TOKEN','test'), patch.object(shim,'aggregation_request',side_effect=RuntimeError('test')):
            with self.assertRaises(RuntimeError):shim.trigger()
        self.assertFalse(shim._activity_context.memory_aggregation)
        lock=shim._lock_for('test-session')
        self.assertTrue(lock.acquire(blocking=False));lock.release()

    def test_authenticated_trigger_rewrites_only_opted_in_request_and_clears_context(self):
        captures=[]
        def fake(*args,**kwargs):
            captures.append((args[1],getattr(shim._activity_context,'memory_aggregation',False)))
            return {'status':'ok'}
        from types import SimpleNamespace
        request=SimpleNamespace(headers={'Authorization':'Bearer test'},get_json=lambda **_:self.payload())
        with patch.object(shim,'AGENT_IDENTITY_PATH',self.identity), patch.object(shim,'TRIGGER_BEARER_TOKEN','test'), patch.object(shim,'legacy_trigger',side_effect=fake), patch.object(shim,'graph_memory_notice',return_value=''), patch.object(shim,'request',request), patch.object(shim,'jsonify',side_effect=lambda x:x):
            for enabled in [True,False]:
                self.config['enabled']=enabled;self.write()
                self.assertEqual(shim.trigger(),{'status':'ok'})
                self.assertFalse(shim._activity_context.memory_aggregation)
            self.assertIn('Resident-consented daily',captures[0][0])
            self.assertIn('LEGACY REQUEST',captures[1][0])
            request.headers['Authorization']='Bearer wrong'
            with patch.object(shim,'abort',side_effect=PermissionError('unauthorized')):
                with self.assertRaises(PermissionError):shim.trigger()

if __name__=='__main__':unittest.main()
