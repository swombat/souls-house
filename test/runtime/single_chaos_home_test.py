"""One Chaos home: CHAOS_AUTH_HOME carries only subscription credentials.

Subscription runs use the main CHAOS_HOME (sessions, history, settings, trust,
hooks) with credentials from oauth-runtime; API-key runs never see
CHAOS_AUTH_HOME; and a subscription run refuses, without starting Chaos, while
the old oauth-runtime store is unmerged or the binary ignores the variable.
"""
import importlib.util
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
spec = importlib.util.spec_from_file_location('single_home_shim', RUNTIME / 'trigger_shim.py')
shim = importlib.util.module_from_spec(spec);sys.modules[spec.name] = shim;spec.loader.exec_module(shim)


def chaos_ok(args, **_):
    return subprocess.CompletedProcess(args, 0, '', '')


class SingleHomeTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name) / 'chaos'
        self.oauth = self.home / 'oauth-runtime'
        self.oauth.mkdir(parents=True)
        # Subscription env builders create their config dirs; keep them in tmp.
        for name, value in (('CHAOS_HOME', self.home), ('OAUTH_CHAOS_HOME', self.oauth),
                            ('CLAUDE_CONFIG_DIR', Path(tmp.name) / 'claude'),
                            ('CHAOS_AGY_HOME', Path(tmp.name) / 'agy'),
                            ('_auth_home_supported', True)):
            p = patch.object(shim, name, value);p.start();self.addCleanup(p.stop)
        p = patch.dict(os.environ, {'SOULSHOUSE_HOME_PROFILE': 'house', 'CHAOS_AUTH_HOME': '/inherited',
                                    'CHAOS_HOME': str(self.home),
                                    'OPENAI_API_KEY': 'sk-api'});p.start();self.addCleanup(p.stop)

    def run_env(self, auth_mode, provider='openai'):
        with patch.object(shim.subprocess, 'run', side_effect=chaos_ok) as run:
            result = shim.run_chaos('test-model', 30, 'request', True, provider=provider, auth_mode=auth_mode)
        return result, run

    def test_subscription_run_uses_the_main_home_and_the_auth_dir(self):
        _, run = self.run_env('oauth_account')
        env = run.call_args.kwargs['env']
        self.assertEqual(env['CHAOS_HOME'], str(self.home))
        self.assertEqual(env['CHAOS_AUTH_HOME'], str(self.oauth))
        self.assertNotIn('OPENAI_API_KEY', env)

    def test_api_key_run_never_inherits_the_auth_dir(self):
        for provider in ('openai', 'xai', 'anthropic'):
            with self.subTest(provider=provider):
                _, run = self.run_env('api_key', provider=provider)
                env = run.call_args.kwargs['env']
                self.assertNotIn('CHAOS_AUTH_HOME', env)
                self.assertEqual(env['CHAOS_HOME'], str(self.home))

    def test_other_subscription_runs_never_inherit_the_auth_dir(self):
        # anthropic and gemini subscriptions rebuild env from os.environ;
        # their final env must still drop an inherited CHAOS_AUTH_HOME.
        for provider in ('anthropic', 'gemini'):
            with self.subTest(provider=provider):
                _, run = self.run_env('oauth_account', provider=provider)
                env = run.call_args.kwargs['env']
                self.assertNotIn('CHAOS_AUTH_HOME', env)

    def test_unmerged_oauth_store_refuses_without_starting_chaos(self):
        (self.oauth / 'config.toml').write_text('storage_url = "postgres://x/y"\n')
        result, run = self.run_env('oauth_account')
        run.assert_not_called()
        self.assertNotEqual(result.returncode, 0)
        failure = shim.runtime_failure([], result.stderr)
        self.assertEqual(failure['code'], 'single_chaos_home_unready')
        self.assertIn('operator merge', failure['message'])
        self.assertNotIn('postgres://', failure['message'])

    def test_merged_store_with_its_config_moved_aside_runs(self):
        (self.oauth / 'config.toml.merged-into-main').write_text('storage_url = "postgres://x/y"\n')
        (self.oauth / 'auth.json').write_text('{}')
        _, run = self.run_env('oauth_account')
        run.assert_called()

    def test_binary_that_ignores_the_variable_refuses(self):
        with patch.object(shim, '_auth_home_supported', False), \
                patch.object(shim.subprocess, 'run', side_effect=chaos_ok) as run:
            result = shim.run_chaos('test-model', 30, 'request', True, provider='openai',
                                    auth_mode='oauth_account')
        # Only the probe ran, and it showed the variable is ignored.
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.kwargs['env']['CHAOS_AUTH_HOME'].split('/')[-1][-7:], 'missing')
        self.assertIn('does not read CHAOS_AUTH_HOME', result.stderr)

    def test_probe_trusts_only_the_named_refusal_and_caches_only_yes(self):
        refusal = subprocess.CompletedProcess([], 1, '', 'Error: CHAOS_AUTH_HOME points to "/x", but that path does not exist')
        other = subprocess.CompletedProcess([], 1, '', 'database unavailable')
        with patch.object(shim, '_auth_home_supported', False):
            with patch.object(shim.subprocess, 'run', return_value=other):
                self.assertFalse(shim.chaos_reads_auth_home())
            with patch.object(shim.subprocess, 'run', return_value=refusal):
                self.assertTrue(shim.chaos_reads_auth_home())
            with patch.object(shim.subprocess, 'run', side_effect=AssertionError('cached')):
                self.assertTrue(shim.chaos_reads_auth_home())

    def test_account_commands_use_the_main_home_with_the_auth_dir(self):
        env = shim._oauth_account_env()
        self.assertEqual(env['CHAOS_HOME'], str(self.home))
        self.assertEqual(env['CHAOS_AUTH_HOME'], str(self.oauth))
        with patch.object(shim, '_auth_home_supported', False), \
                patch.object(shim.subprocess, 'run', side_effect=chaos_ok):
            with self.assertRaises(RuntimeError):
                shim._oauth_account_env()


@unittest.skipUnless(os.environ.get('CHAOS_TEST_BIN'), 'set CHAOS_TEST_BIN to a Chaos with seuros/chaos#152')
class RealChaosAuthHomeTest(unittest.TestCase):
    """The real binary: the probe answers yes, and a missing auth dir fails even
    when the main home holds valid-looking credentials (no fallback)."""

    def test_probe_and_no_fallback(self):
        chaos_bin = os.environ['CHAOS_TEST_BIN']
        with tempfile.TemporaryDirectory() as td:
            home = Path(td) / 'chaos'
            (home / 'tmp').mkdir(parents=True)
            (home / 'auth.json').write_text('{"OPENAI_API_KEY": "sk-main-home"}')
            env = {'PATH': '/usr/local/bin:/usr/bin:/bin', 'HOME': td, 'CHAOS_HOME': str(home)}
            with patch.dict(os.environ, env, clear=True), patch.object(shim, 'CHAOS_HOME', home), \
                    patch.object(shim, 'CHAOS_BIN', chaos_bin), \
                    patch.object(shim, '_auth_home_supported', False):
                self.assertTrue(shim.chaos_reads_auth_home())
            result = subprocess.run(
                [chaos_bin, '--provider', 'openai', 'accounts', 'status'],
                capture_output=True, text=True, timeout=60,
                env={**env, 'CHAOS_AUTH_HOME': str(Path(td) / 'absent')})
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('sk-main-home', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
