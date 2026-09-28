"""Imported home as a class of profile: mira_v1 unchanged, portable_v1 added."""
import hashlib
import importlib.util
import json
import logging
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

RUNTIME = Path(__file__).resolve().parents[2] / 'agent-runtime'
sys.path.insert(0, str(RUNTIME))
import imported_home
import home_sync_loop
os.environ.setdefault("TRIGGER_BEARER_TOKEN", "test-token")
spec = importlib.util.spec_from_file_location('portable_profile_shim', RUNTIME / 'trigger_shim.py')
shim = importlib.util.module_from_spec(spec);sys.modules[spec.name] = shim;spec.loader.exec_module(shim)

# sha256 of imported_runtime_context() for mira_v1 at origin/master 7daf9ea.
MIRA_HOSTING_CONTEXT_SHA256 = 'a2a7c7b575d13dfd5034649f21881cd2c6110974bcd54ed7a3ffda5d9d91a2a2'


def make_home(root, profile, identity, sync=None):
    manifest = {'format': 'souls-home/v1', 'profile': profile, 'identity_id': identity, 'graph': 'external'}
    for key in ('instructions', 'soul', 'narrative', 'journal_reader'):
        manifest[key] = key + '.md'
        (root / manifest[key]).write_text('PRIVATE HOME TEXT')
    manifest['hooks'] = '.chaos/hooks.json'
    (root / '.chaos').mkdir(exist_ok=True)
    (root / '.chaos/hooks.json').write_text(json.dumps({'hooks': {k: [{}] for k in ('SessionStart', 'BeforeTurn', 'Stop')}}))
    if sync is not None:
        manifest['sync'] = sync
    (root / 'resident-home.json').write_text(json.dumps(manifest))
    return manifest


class HomeFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name).resolve()
        self.mira = base / 'mira';self.mira.mkdir()
        self.lume = base / 'lume';self.lume.mkdir()
        self.outside = base / 'outside';self.outside.mkdir()
        make_home(self.mira, 'mira_v1', 'test-mira')
        (self.mira / 'shared/automation/scripts').mkdir(parents=True)
        (self.mira / 'shared/automation/scripts/git_sync.py').write_text('print("mira sync")\n')
        (self.lume / 'automation/scripts').mkdir(parents=True)
        (self.lume / 'automation/scripts/home_sync.py').write_text('print("lume sync")\n')
        make_home(self.lume, 'portable_v1', 'test-lume', sync='automation/scripts/home_sync.py')

    def env(self, **values):
        base = {'SOULSHOUSE_HOME_PROFILE': None, 'MIRA_ROOT': None, 'SOULSHOUSE_HOME_ROOT': None,
                'SOULSHOUSE_PORTABLE_HOME_ID': None}
        base.update(values)
        clean = {k: v for k, v in os.environ.items() if k not in base}
        clean.update({k: v for k, v in base.items() if v is not None})
        return patch.dict(os.environ, clean, clear=True)

    def mira_env(self):
        return self.env(SOULSHOUSE_HOME_PROFILE='mira_v1', MIRA_ROOT=str(self.mira), SOULSHOUSE_PORTABLE_HOME_ID='test-mira')

    def lume_env(self, **extra):
        return self.env(SOULSHOUSE_HOME_PROFILE='portable_v1', SOULSHOUSE_HOME_ROOT=str(self.lume),
                        SOULSHOUSE_PORTABLE_HOME_ID='test-lume', **extra)

    def set_sync(self, value):
        manifest = json.loads((self.lume / 'resident-home.json').read_text())
        if value is None:
            manifest.pop('sync', None)
        else:
            manifest['sync'] = value
        (self.lume / 'resident-home.json').write_text(json.dumps(manifest))
        return manifest


class ProfileTest(HomeFixture):
    # --- profiles -------------------------------------------------------

    def test_both_imported_profiles_validate(self):
        with self.mira_env():
            self.assertTrue(imported_home.enabled())
            self.assertEqual(imported_home.validate()[0], self.mira)
            self.assertEqual(imported_home.root_env_name(), 'MIRA_ROOT')
        with self.lume_env():
            self.assertTrue(imported_home.enabled())
            self.assertEqual(imported_home.validate()[0], self.lume)
            self.assertEqual(imported_home.root_env_name(), 'SOULSHOUSE_HOME_ROOT')

    def test_house_is_default_and_empty_profile_is_house(self):
        with self.env():
            self.assertFalse(imported_home.enabled())
        with self.env(SOULSHOUSE_HOME_PROFILE=''):
            self.assertEqual(imported_home.home_class(), 'house')

    def test_unknown_profile_fails_everywhere_and_never_falls_back(self):
        with self.env(SOULSHOUSE_HOME_PROFILE='mira_v2', MIRA_ROOT=str(self.mira), SOULSHOUSE_HOME_ROOT=str(self.lume)):
            for call in (imported_home.enabled, imported_home.validate, imported_home.home_class, imported_home.home_root):
                with self.subTest(call=call.__name__), self.assertRaises(ValueError):
                    call()
            with patch.object(shim.subprocess, 'run') as run, self.assertRaises(ValueError):
                shim.run_chaos('test-model', 30, 'request', True)
            run.assert_not_called()

    def test_container_start_check_exits_non_zero_for_unknown_profile(self):
        script = str(RUNTIME / 'imported_home.py')
        env = {'PATH': os.environ.get('PATH', ''), 'SOULSHOUSE_HOME_PROFILE': 'mira_v2'}
        result = subprocess.run([sys.executable, script, '--class'], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unknown resident home profile', result.stderr)
        for profile, expected in (('house', 'house'), ('mira_v1', 'imported'), ('portable_v1', 'imported')):
            env['SOULSHOUSE_HOME_PROFILE'] = profile
            result = subprocess.run([sys.executable, script, '--class'], env=env, capture_output=True, text=True)
            self.assertEqual((result.returncode, result.stdout.strip()), (0, expected))

    def test_portable_profile_never_reads_mira_root(self):
        with self.env(SOULSHOUSE_HOME_PROFILE='portable_v1', MIRA_ROOT=str(self.lume), SOULSHOUSE_PORTABLE_HOME_ID='test-lume'):
            with self.assertRaises(ValueError):
                imported_home.validate()

    def test_mira_profile_still_reads_mira_root_only(self):
        with self.env(SOULSHOUSE_HOME_PROFILE='mira_v1', SOULSHOUSE_HOME_ROOT=str(self.mira), SOULSHOUSE_PORTABLE_HOME_ID='test-mira'):
            with self.assertRaises(ValueError):
                imported_home.validate()

    def test_manifest_profile_must_match_container_profile(self):
        with self.env(SOULSHOUSE_HOME_PROFILE='mira_v1', MIRA_ROOT=str(self.lume), SOULSHOUSE_PORTABLE_HOME_ID='test-lume'):
            with self.assertRaises(ValueError):
                imported_home.validate()
        with self.env(SOULSHOUSE_HOME_PROFILE='portable_v1', SOULSHOUSE_HOME_ROOT=str(self.mira), SOULSHOUSE_PORTABLE_HOME_ID='test-mira'):
            with self.assertRaises(ValueError):
                imported_home.validate()

    def test_entrypoint_branches_on_profile_class_not_a_literal(self):
        text = (RUNTIME / 'entrypoint.sh').read_text()
        self.assertNotIn('= "mira_v1"', text)
        self.assertIn('HOME_CLASS="$(python3 /home/agent/imported_home.py --class)"', text)
        self.assertIn('test "$AGENT_REPO_PATH" = "$(python3 /home/agent/imported_home.py --root)"', text)

    # --- hosting context -------------------------------------------------

    def test_mira_hosting_context_is_byte_identical(self):
        with self.mira_env():
            text = shim.imported_runtime_context()
        self.assertEqual(hashlib.sha256(text.encode()).hexdigest(), MIRA_HOSTING_CONTEXT_SHA256)

    def test_portable_hosting_context_names_its_own_root(self):
        with self.lume_env():
            text = shim.imported_runtime_context()
        self.assertIn('SOULSHOUSE_HOME_ROOT', text)
        self.assertNotIn('MIRA_ROOT', text)
        self.assertNotIn('Dell', text)

    def test_portable_run_uses_its_home_and_instructions(self):
        with self.lume_env(), patch.object(imported_home, 'require_runtime_trust') as trust, patch.object(shim.subprocess, 'run') as run:
            shim.run_chaos('test-model', 30, 'request', True)
        args = run.call_args.args[0]
        self.assertEqual(args[args.index('-C') + 1], str(self.lume))
        self.assertIn('model_instructions_file=' + json.dumps(str(self.lume / 'instructions.md')), args)
        trust.assert_called_once()

    # --- manifest sync path ---------------------------------------------

    def test_manifest_sync_path_is_validated(self):
        (self.outside / 'evil.py').write_text('print("escape")\n')
        (self.lume / 'automation/scripts/empty.py').write_text('')
        (self.lume / 'automation/scripts/sync.sh').write_text('echo no\n')
        (self.lume / 'automation/scripts/link.py').symlink_to(self.outside / 'evil.py')
        bad = {
            'absolute': str(self.outside / 'evil.py'),
            'traversal out': '../outside/evil.py',
            'traversal back in': 'automation/../automation/scripts/home_sync.py',
            'symlink escape': 'automation/scripts/link.py',
            'missing': 'automation/scripts/nope.py',
            'empty': 'automation/scripts/empty.py',
            'not python': 'automation/scripts/sync.sh',
            'not a string': ['python3', 'x.py'],
            'blank': '',
        }
        with self.lume_env():
            for label, value in bad.items():
                with self.subTest(label):
                    self.set_sync(value)
                    with self.assertRaises(ValueError):
                        imported_home.validate()
            self.set_sync('automation/scripts/home_sync.py')
            root, manifest = imported_home.validate()
            self.assertEqual(imported_home.sync_script(root, manifest), self.lume / 'automation/scripts/home_sync.py')

    def test_portable_profile_requires_a_sync_script(self):
        self.set_sync(None)
        with self.lume_env(), self.assertRaises(ValueError):
            imported_home.validate()

    def test_mira_default_sync_path_is_the_compatibility_default(self):
        manifest = json.loads((self.mira / 'resident-home.json').read_text())
        self.assertNotIn('sync', manifest)
        with self.mira_env():
            self.assertEqual(imported_home.sync_relative_path(manifest), 'shared/automation/scripts/git_sync.py')
            self.assertEqual(imported_home.sync_script(self.mira, manifest), self.mira / 'shared/automation/scripts/git_sync.py')

    def test_mira_turns_do_not_depend_on_her_default_sync_script(self):
        (self.mira / 'shared/automation/scripts/git_sync.py').unlink()
        with self.mira_env():
            self.assertEqual(imported_home.validate()[0], self.mira)

    def test_mira_may_declare_her_own_sync_path(self):
        (self.mira / 'sync.py').write_text('print(1)\n')
        manifest = json.loads((self.mira / 'resident-home.json').read_text())
        manifest['sync'] = 'sync.py'
        (self.mira / 'resident-home.json').write_text(json.dumps(manifest))
        with self.mira_env():
            root, manifest = imported_home.validate()
            self.assertEqual(imported_home.sync_script(root, manifest), self.mira / 'sync.py')


class MiraManifestCompatibilityTest(unittest.TestCase):
    """Mira's resident-home.json and .chaos/hooks.json as they exist today
    (2026-09-28), copied field for field, with placeholder file contents."""

    MANIFEST = {
        "format": "souls-home/v1", "identity_id": "mira-tenner", "profile": "mira_v1",
        "instructions": "instructions.md", "soul": "soul.md", "narrative": "self-narrative.md",
        "hooks": ".chaos/hooks.json", "graph": "external",
        "journal_reader": "shared/automation/journal_entries.py",
    }

    def test_her_current_manifest_validates_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            for key in ('instructions', 'soul', 'narrative', 'journal_reader'):
                path = root / self.MANIFEST[key];path.parent.mkdir(parents=True, exist_ok=True);path.write_text('x')
            (root / '.chaos').mkdir()
            command = 'python3 "${MIRA_ROOT:-$HOME/dev/mira}"/shared/automation/%s'
            hooks = {'hooks': {
                'SessionStart': [{'matcher': '^startup$', 'hooks': [{'type': 'command', 'command': command % 'wake.py', 'timeout': 10}]}],
                'BeforeTurn': [{'hooks': [{'type': 'command', 'command': command % 'before_turn.py', 'timeout': 5}]}],
                'Stop': [{'hooks': [{'type': 'command', 'command': command % 'stop_trace.py', 'timeout': 60}]}],
            }}
            (root / '.chaos/hooks.json').write_text(json.dumps(hooks))
            (root / 'resident-home.json').write_text(json.dumps(self.MANIFEST))
            env = {'SOULSHOUSE_HOME_PROFILE': 'mira_v1', 'MIRA_ROOT': str(root), 'SOULSHOUSE_PORTABLE_HOME_ID': 'mira-tenner'}
            with patch.dict(os.environ, env):
                self.assertEqual(imported_home.validate(), (root, self.MANIFEST))
                self.assertEqual(imported_home.sync_relative_path(self.MANIFEST), 'shared/automation/scripts/git_sync.py')


class Completed:
    def __init__(self, returncode):
        self.returncode = returncode


class SyncLoopTest(HomeFixture):
    def setUp(self):
        super().setUp()
        self.status = Path(self.tmp.name) / 'state/home-sync/status.json'

    def test_success_runs_argv_without_shell_and_records_ok(self):
        calls = []
        def runner(args, **kwargs):
            calls.append((args, kwargs));return Completed(0)
        with self.lume_env():
            status = home_sync_loop.run_once(runner=runner, path=self.status)
        args, kwargs = calls[0]
        self.assertEqual(args, ['python3', str(self.lume / 'automation/scripts/home_sync.py')])
        self.assertNotIn('shell', kwargs)
        self.assertEqual(kwargs['cwd'], self.lume)
        self.assertEqual(status['state'], 'ok')
        self.assertEqual(json.loads(self.status.read_text())['state'], 'ok')
        self.assertEqual(home_sync_loop.health(self.status)['state'], 'ok')

    def test_mira_default_script_is_run_as_before(self):
        calls = []
        with self.mira_env():
            home_sync_loop.run_once(runner=lambda args, **kw: calls.append(args) or Completed(0), path=self.status)
        self.assertEqual(calls, [['python3', str(self.mira / 'shared/automation/scripts/git_sync.py')]])

    def assert_failure(self, runner, expected):
        with self.lume_env(), self.assertLogs('home-sync', level=logging.ERROR) as logs:
            status = home_sync_loop.run_once(runner=runner, path=self.status)
        self.assertEqual(status['state'], 'error')
        self.assertIn(expected, status['last_error'])
        self.assertIn(expected, '\n'.join(logs.output))
        self.assertEqual(home_sync_loop.health(self.status)['state'], 'error')
        return status

    def test_missing_script_is_an_error_signal_not_a_silent_skip(self):
        (self.lume / 'automation/scripts/home_sync.py').unlink()
        runner = lambda *a, **k: self.fail('must not run a missing script')
        self.assert_failure(runner, 'sync script unavailable')

    def test_failed_sync_is_an_error_signal(self):
        self.assert_failure(lambda *a, **k: Completed(3), 'exited with status 3')

    def test_timeout_is_an_error_signal_and_failures_accumulate(self):
        def runner(*args, **kwargs):
            raise subprocess.TimeoutExpired('python3', 300)
        self.assert_failure(runner, 'timed out')
        status = self.assert_failure(runner, 'timed out')
        self.assertEqual(status['consecutive_failures'], 2)
        with self.lume_env():
            status = home_sync_loop.run_once(runner=lambda *a, **k: Completed(0), path=self.status)
        self.assertEqual((status['state'], status['consecutive_failures']), ('ok', 0))

    def test_stopped_loop_reads_as_stale(self):
        from datetime import datetime, timedelta, timezone
        with self.lume_env():
            home_sync_loop.run_once(runner=lambda *a, **k: Completed(0), path=self.status)
        later = datetime.now(timezone.utc) + timedelta(hours=1)
        self.assertEqual(home_sync_loop.health(self.status, now=later)['state'], 'stale')
        self.assertEqual(home_sync_loop.health(Path(self.tmp.name) / 'absent.json')['state'], 'unknown')

    def test_health_endpoint_exposes_sync_only_for_imported_homes(self):
        with self.lume_env(SOULSHOUSE_HOME_SYNC_STATUS=str(self.status)), \
                patch.object(shim, 'jsonify', side_effect=lambda body: body), \
                patch.object(shim, '_chaos_version', return_value='test'):
            home_sync_loop.run_once(runner=lambda *a, **k: Completed(1))
            body = shim.health()
        self.assertEqual(body['status'], 'ok')
        self.assertEqual(body['home_sync']['state'], 'error')
        with self.env(), patch.object(shim, 'jsonify', side_effect=lambda body: body), \
                patch.object(shim, '_chaos_version', return_value='test'):
            self.assertNotIn('home_sync', shim.health())


if __name__ == '__main__':
    unittest.main()
