"""A stock fresh prompt carries soul/self-narrative once: in Chaos's protected
snapshot when every home will snapshot them whole, otherwise in the prompt."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

RUNTIME = Path(__file__).resolve().parents[2] / 'agent-runtime'
sys.path.insert(0, str(RUNTIME))
os.environ.setdefault("TRIGGER_BEARER_TOKEN", "test-token")
spec = importlib.util.spec_from_file_location('protected_shim', RUNTIME / 'trigger_shim.py')
shim = importlib.util.module_from_spec(spec);sys.modules[spec.name] = shim;spec.loader.exec_module(shim)
rs_spec = importlib.util.spec_from_file_location('runtime_settings_p', RUNTIME / 'runtime_settings.py')
settings = importlib.util.module_from_spec(rs_spec);rs_spec.loader.exec_module(settings)

SOUL, NARRATIVE = 'SOUL TEXT 7d1', 'NARRATIVE TEXT 9c4'


class ProtectedIdentityTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup)
        base = Path(tmp.name).resolve()
        self.identity = base/'identity';self.identity.mkdir()
        (self.identity/'soul.md').write_text(SOUL)
        (self.identity/'self-narrative.md').write_text(NARRATIVE)
        self.home = base/'chaos';self.oauth = self.home/'oauth-runtime';self.oauth.mkdir(parents=True)
        self.files = [str(self.identity/'soul.md'), str(self.identity/'self-narrative.md')]
        self.reset()
        for name, value in (('AGENT_IDENTITY_PATH', self.identity), ('CHAOS_HOME', self.home),
                            ('OAUTH_CHAOS_HOME', self.oauth)):
            p = patch.object(shim, name, value);p.start();self.addCleanup(p.stop)
        p = patch.object(shim, 'runtime_context', return_value='RUNTIME');p.start();self.addCleanup(p.stop)

    def reset(self):
        self.settings = {self.home: {'protected_context_files': list(self.files)},
                         self.oauth: {'protected_context_files': list(self.files)}}

    def fake_run(self, args, env=None, **_):
        home = Path(env['CHAOS_HOME'])
        if home not in self.settings:
            return subprocess.CompletedProcess(args, 1, '', 'no settings')
        return subprocess.CompletedProcess(args, 0, json.dumps(self.settings[home]), '')

    def context(self):
        with patch.object(shim.subprocess, 'run', side_effect=self.fake_run):
            return shim.identity_context()

    def test_protected_in_every_home_means_one_copy(self):
        text = self.context()
        self.assertNotIn(SOUL, text)
        self.assertNotIn(NARRATIVE, text)
        self.assertIn('RUNTIME', text)

    def test_any_doubt_keeps_the_prompt_copy(self):
        cases = {
            'oauth home opted out': lambda: self.settings[self.oauth].update(protected_context_files=[]),
            'settings unreadable': lambda: self.settings.pop(self.oauth),
            'over the cap (Chaos would truncate)': lambda: [s.update(protected_context_max_bytes=10)
                                                           for s in self.settings.values()],
            'cap of zero (Chaos snapshots nothing)': lambda: [s.update(protected_context_max_bytes=0)
                                                             for s in self.settings.values()],
            'listed file missing': lambda: [s.update(protected_context_files=self.files + ['/nonexistent'])
                                            for s in self.settings.values()],
        }
        for name, change in cases.items():
            with self.subTest(case=name):
                self.reset()
                change()
                text = self.context()
                self.assertIn(SOUL, text)
                self.assertIn(NARRATIVE, text)

    def test_only_the_protected_file_is_dropped(self):
        for s in self.settings.values():
            s['protected_context_files'] = self.files[:1]
        text = self.context()
        self.assertNotIn(SOUL, text)
        self.assertIn(NARRATIVE, text)

    @unittest.skipUnless(os.environ.get('CHAOS_TEST_BIN'), 'set CHAOS_TEST_BIN for the real-Chaos path')
    def test_boot_defaults_then_real_chaos_settings_give_one_copy(self):
        env = {'CHAOS_BIN': os.environ['CHAOS_TEST_BIN'], 'CHAOS_HOME': str(self.home),
               'SOULSHOUSE_HOME_PROFILE': '', 'AGENT_IDENTITY_PATH': str(self.identity),
               'SOULSHOUSE_APP_URL': '', 'HELIXKIT_APP_URL': ''}
        with patch.dict(os.environ, env), patch.object(shim, 'CHAOS_BIN', os.environ['CHAOS_TEST_BIN']):
            settings.main()
            text = shim.identity_context()
        self.assertNotIn(SOUL, text)
        self.assertNotIn(NARRATIVE, text)


if __name__ == '__main__':
    unittest.main()
