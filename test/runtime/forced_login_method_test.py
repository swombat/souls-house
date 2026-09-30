"""Pins the imported-home forced_login_method choice and its default-off switch."""
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
spec = importlib.util.spec_from_file_location('forced_login_shim', RUNTIME / 'trigger_shim.py')
shim = importlib.util.module_from_spec(spec);sys.modules[spec.name] = shim;spec.loader.exec_module(shim)

SWITCH = 'SOULSHOUSE_IMPORTED_CLAMP_OMIT_FORCED_LOGIN'


class ChoiceTest(unittest.TestCase):
    CURRENT = {
        ('openai', 'oauth_account'): 'chatgpt',
        ('openai', 'api_key'): 'api',
        ('anthropic', 'api_key'): 'api',
        ('anthropic', 'oauth_account'): 'api',
        ('gemini', 'oauth_account'): 'api',
        ('xai', 'api_key'): 'api',
    }

    def test_default_is_current_behaviour(self):
        for (provider, mode), expected in self.CURRENT.items():
            with self.subTest(provider=provider, mode=mode):
                self.assertEqual(shim.imported_forced_login_method(provider, mode, environ={}), expected)
                self.assertEqual(shim.imported_forced_login_method(provider, mode, environ={SWITCH: '0'}), expected)

    def test_switch_omits_only_for_anthropic_subscription_clamp(self):
        for (provider, mode), expected in self.CURRENT.items():
            with self.subTest(provider=provider, mode=mode):
                result = shim.imported_forced_login_method(provider, mode, environ={SWITCH: '1'})
                if (provider, mode) == ('anthropic', 'oauth_account'):
                    self.assertIsNone(result)
                else:
                    self.assertEqual(result, expected)


class RunChaosTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        manifest = {'format': 'souls-home/v1', 'profile': 'mira_v1', 'identity_id': 'test-mira', 'graph': 'external'}
        for key in ('instructions', 'soul', 'narrative', 'journal_reader'):
            manifest[key] = key + '.md';(self.root / manifest[key]).write_text('TEXT')
        manifest['hooks'] = 'hooks.json'
        (self.root / 'hooks.json').write_text(json.dumps({'hooks': {k: [{}] for k in ('SessionStart', 'BeforeTurn', 'Stop')}}))
        (self.root / 'resident-home.json').write_text(json.dumps(manifest))
        self.claude = self.root / 'claude-state'

    def run_args(self, profile, provider, mode, switch=None, resume=None):
        env = {'SOULSHOUSE_HOME_PROFILE': profile, 'MIRA_ROOT': str(self.root), 'SOULSHOUSE_PORTABLE_HOME_ID': 'test-mira'}
        if switch is not None:
            env[SWITCH] = switch
        with patch.dict(os.environ, env), patch.object(shim, 'OAUTH_CHAOS_HOME', self.root / 'oauth'), \
                patch.object(shim, 'CLAUDE_CONFIG_DIR', self.claude), \
                patch.object(imported_home, 'require_runtime_trust'), patch.object(shim.subprocess, 'run') as run:
            shim.run_chaos('test-model', 30, 'request', True, provider=provider, auth_mode=mode, resume_id=resume)
        return run.call_args.args[0]

    def test_imported_anthropic_subscription_keeps_api_login_by_default(self):
        for resume in (None, 'existing-session'):
            with self.subTest(resume=resume):
                args = self.run_args('mira_v1', 'anthropic', 'oauth_account', resume=resume)
                self.assertIn('clamp=true', args)
                self.assertIn('forced_login_method="api"', args)

    def test_switch_drops_forced_login_for_anthropic_clamp_fresh_and_resumed(self):
        for resume in (None, 'existing-session'):
            with self.subTest(resume=resume):
                args = self.run_args('mira_v1', 'anthropic', 'oauth_account', switch='1', resume=resume)
                self.assertIn('clamp=true', args)
                self.assertFalse(any(a.startswith('forced_login_method=') for a in args))

    def test_openai_subscription_path_is_unchanged_with_switch_on(self):
        for switch in (None, '1'):
            with self.subTest(switch=switch):
                args = self.run_args('mira_v1', 'openai', 'oauth_account', switch=switch)
                self.assertIn('forced_login_method="chatgpt"', args)
                self.assertNotIn('clamp=true', args)

    def test_api_key_path_is_unchanged_with_switch_on(self):
        for switch in (None, '1'):
            with self.subTest(switch=switch):
                self.assertIn('forced_login_method="api"', self.run_args('mira_v1', 'anthropic', 'api_key', switch=switch))

    def test_house_residents_never_get_a_forced_login(self):
        for provider, mode in (('anthropic', 'oauth_account'), ('anthropic', 'api_key'), ('openai', 'oauth_account')):
            for switch in (None, '1'):
                with self.subTest(provider=provider, mode=mode, switch=switch):
                    args = self.run_args('house', provider, mode, switch=switch)
                    self.assertFalse(any(a.startswith('forced_login_method=') for a in args))


if __name__ == '__main__':
    unittest.main()
