import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

RUNTIME = Path(__file__).resolve().parents[2] / 'agent-runtime'
sys.path.insert(0, str(RUNTIME))
import imported_home
os.environ.setdefault("TRIGGER_BEARER_TOKEN", "test-token")
spec = importlib.util.spec_from_file_location('portable_shim', RUNTIME / 'trigger_shim.py')
shim = importlib.util.module_from_spec(spec);sys.modules[spec.name] = shim;spec.loader.exec_module(shim)

class HomeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.manifest = {'format':'souls-home/v1','profile':'mira_v1','identity_id':'test-mira','graph':'external'}
        for key in ('instructions','soul','narrative','journal_reader'):
            self.manifest[key] = key+'.md';(self.root/self.manifest[key]).write_text('PRIVATE HOME TEXT')
        self.manifest['hooks'] = 'hooks.json'
        (self.root/'hooks.json').write_text(json.dumps({'hooks':{k:[{}] for k in ('SessionStart','BeforeTurn','Stop')}}))
        self.save()
        env = patch.dict(os.environ, {'MIRA_ROOT':str(self.root),'SOULSHOUSE_HOME_PROFILE':'mira_v1','SOULSHOUSE_PORTABLE_HOME_ID':'test-mira'})
        env.start();self.addCleanup(env.stop)

    def save(self):
        (self.root/'resident-home.json').write_text(json.dumps(self.manifest))

    def test_validates_identity_and_files(self):
        self.assertEqual(imported_home.validate()[0], self.root)
        self.manifest['identity_id']='other';self.save()
        with self.assertRaises(ValueError):imported_home.validate()

    def test_missing_root_and_escape_fail(self):
        self.manifest['instructions']='../outside';self.save()
        with self.assertRaises(ValueError):imported_home.validate()
        self.manifest['instructions']='missing';self.save()
        with self.assertRaises(ValueError):imported_home.validate()

    def test_home_prompt_does_not_duplicate_wake_or_house_memory(self):
        with patch.object(shim, 'memory_context', side_effect=AssertionError('stock journal read')), patch.object(shim, 'identity_context', side_effect=AssertionError('duplicate identity')):
            prompt, info = shim.build_prompt_with_components('REQUEST')
        self.assertIn('REQUEST', prompt)
        self.assertNotIn('PRIVATE HOME TEXT', prompt)
        self.assertEqual(info['journal'], 0)
        self.assertEqual(shim.memory_command_reference(), '')

    def test_execution_uses_home_instructions_and_cwd(self):
        with patch.object(imported_home, 'require_runtime_trust'), patch.object(shim.subprocess, 'run') as run:
            shim.run_chaos('test-model', 30, 'request', True)
        args = run.call_args.args[0]
        self.assertEqual(args[args.index('-C')+1], str(self.root))
        self.assertIn('model_instructions_file='+json.dumps(str(self.root/'instructions.md')), args)
        self.assertIn('forced_login_method="api"', args)
        self.assertFalse(any(arg.startswith("mcp_servers.") for arg in args))

    def test_stock_path_is_not_validated(self):
        with patch.dict(os.environ, {'SOULSHOUSE_HOME_PROFILE':'house'}), patch.object(imported_home, 'validate', side_effect=AssertionError('stock touched')), patch.object(shim, 'identity_context', return_value='STOCK'), patch.object(shim, 'memory_context', return_value='JOURNAL'):
            prompt, _ = shim.build_prompt_with_components('REQUEST')
        self.assertTrue(prompt.startswith('STOCK'))

    def test_effective_trust_required(self):
        import sqlite3
        with self.assertRaises(ValueError):
            imported_home.require_runtime_trust(self.root, self.root)
        with sqlite3.connect(self.root/'chaos.sqlite') as db:
            db.execute('CREATE TABLE project_trust(project_path TEXT, trust_level TEXT)')
            db.execute('INSERT INTO project_trust VALUES(?,?)', (str(self.root), 'untrusted'))
        with self.assertRaises(ValueError):
            imported_home.require_runtime_trust(self.root, self.root)
        with sqlite3.connect(self.root/'chaos.sqlite') as db:
            db.execute("UPDATE project_trust SET trust_level='trusted'")
        imported_home.require_runtime_trust(self.root, self.root)
