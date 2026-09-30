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


LUME_SYNC_STATUS = 'automation/state/home-sync/status.json'


def make_home(root, profile, identity, sync=None, sync_status=None):
    manifest = {'format': 'souls-home/v1', 'profile': profile, 'identity_id': identity, 'graph': 'external'}
    for key in ('instructions', 'soul', 'narrative', 'journal_reader'):
        manifest[key] = key + '.md'
        (root / manifest[key]).write_text('PRIVATE HOME TEXT')
    manifest['hooks'] = '.chaos/hooks.json'
    (root / '.chaos').mkdir(exist_ok=True)
    (root / '.chaos/hooks.json').write_text(json.dumps({'hooks': {k: [{}] for k in ('SessionStart', 'BeforeTurn', 'Stop')}}))
    if sync is not None:
        manifest['sync'] = sync
    if sync_status is not None:
        manifest['sync_status'] = sync_status
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
        make_home(self.lume, 'portable_v1', 'test-lume', sync='automation/scripts/home_sync.py',
                  sync_status=LUME_SYNC_STATUS)

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

    @staticmethod
    def hooks():
        command = 'python3 "${MIRA_ROOT:-$HOME/dev/mira}"/shared/automation/%s'
        return {'hooks': {
            'SessionStart': [{'matcher': '^startup$', 'hooks': [{'type': 'command', 'command': command % 'wake.py',
                                                                 'timeout': 10, 'statusMessage': "Loading Mira's wake context"}]}],
            'BeforeTurn': [{'hooks': [{'type': 'command', 'command': command % 'before_turn.py',
                                       'timeout': 5, 'statusMessage': "Checking Mira's before-turn context"}]}],
            'Stop': [{'hooks': [{'type': 'command', 'command': command % 'stop_trace.py',
                                 'timeout': 60, 'statusMessage': "Inviting Mira's journal reflex"}]}],
        }}

    def test_her_current_manifest_validates_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            for key in ('instructions', 'soul', 'narrative', 'journal_reader'):
                path = root / self.MANIFEST[key];path.parent.mkdir(parents=True, exist_ok=True);path.write_text('x')
            (root / '.chaos').mkdir()
            (root / '.chaos/hooks.json').write_text(json.dumps(self.hooks()))
            (root / 'resident-home.json').write_text(json.dumps(self.MANIFEST))
            env = {'SOULSHOUSE_HOME_PROFILE': 'mira_v1', 'MIRA_ROOT': str(root), 'SOULSHOUSE_PORTABLE_HOME_ID': 'mira-tenner'}
            with patch.dict(os.environ, env):
                self.assertEqual(imported_home.validate(), (root, self.MANIFEST))
                self.assertEqual(imported_home.sync_relative_path(self.MANIFEST), 'shared/automation/scripts/git_sync.py')


class Completed:
    def __init__(self, returncode):
        self.returncode = returncode


def local_now():
    # home_sync.py's now_iso(): local time, seconds, with offset.
    from datetime import datetime
    return datetime.now().astimezone().isoformat(timespec='seconds')


def writes_status(status_file, status, code, **fields):
    """A fake sync run that writes its own status file the way home_sync.py does."""
    def runner(*args, **kwargs):
        previous = {}
        if status_file.exists():
            previous = json.loads(status_file.read_text())
        state = dict(previous) if status == 'busy' else {
            'last_success_at': previous.get('last_success_at'),
            'consecutive_failures': previous.get('consecutive_failures', 0) + 1}
        state.update(status=status, checked_at=local_now(), **fields)
        if status == 'ok':
            state.update(last_success_at=state['checked_at'], consecutive_failures=0)
        status_file.parent.mkdir(parents=True, exist_ok=True)
        status_file.write_text(json.dumps(state))
        return Completed(code)
    return runner


class SyncLoopTest(HomeFixture):
    def setUp(self):
        super().setUp()
        self.status = Path(self.tmp.name) / 'state/home-sync/status.json'

    def ok(self):
        return writes_status(self.lume / LUME_SYNC_STATUS, 'ok', 0)

    def test_success_runs_argv_without_shell_and_records_ok(self):
        calls = []
        succeed = self.ok()
        def runner(args, **kwargs):
            calls.append((args, kwargs));return succeed()
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
            status = home_sync_loop.run_once(runner=self.ok(), path=self.status)
        self.assertEqual((status['state'], status['consecutive_failures']), ('ok', 0))

    def test_stopped_loop_reads_as_stale(self):
        from datetime import datetime, timedelta, timezone
        with self.lume_env():
            home_sync_loop.run_once(runner=self.ok(), path=self.status)
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



class SyncConfirmationTest(HomeFixture):
    """Mira's review of PR 106: invoking the script is not a confirmed sync.
    A skip, or a clean exit nobody can confirm, preserves the last real success
    and the failure count."""

    T0 = '2026-09-29T08:00:00+00:00'

    def setUp(self):
        super().setUp()
        self.status = Path(self.tmp.name) / 'state/home-sync/status.json'
        self.lume_status = self.lume / LUME_SYNC_STATUS

    def seed(self, **fields):
        base = {'state': 'ok', 'last_success_at': self.T0, 'consecutive_failures': 0}
        base.update(fields)
        home_sync_loop.write_status(base, self.status)

    def run_lume(self, runner):
        with self.lume_env(), _quiet():
            return home_sync_loop.run_once(runner=runner, path=self.status)

    def run_mira(self, runner):
        with self.mira_env(), _quiet():
            return home_sync_loop.run_once(runner=runner, path=self.status)

    # --- Mira: git_sync.py exits 0 when another sync holds the lock ----------
    def test_mira_lock_held_skip_after_failure_preserves_last_success(self):
        self.seed()
        failed = self.run_mira(lambda *a, **k: Completed(1))
        self.assertEqual((failed['state'], failed['consecutive_failures']), ('error', 1))
        skipped = self.run_mira(lambda *a, **k: Completed(0))  # lock held: exit 0, nothing done
        self.assertEqual(skipped['last_success_at'], self.T0)
        self.assertEqual(skipped['consecutive_failures'], 1)
        self.assertEqual(skipped['state'], 'error')
        self.assertEqual(skipped['last_outcome'], 'unconfirmed')
        self.assertEqual(skipped['last_error'], 'sync exited with status 1')
        self.assertEqual(home_sync_loop.health(self.status)['state'], 'error')

    def test_mira_clean_exit_alone_is_never_evidence_of_success(self):
        status = self.run_mira(lambda *a, **k: Completed(0))
        self.assertEqual((status['state'], status['last_success_at']), ('unconfirmed', None))
        self.assertEqual(status['confirmed_by'], 'exit_code')
        status = self.run_mira(lambda *a, **k: Completed(0))
        self.assertEqual((status['state'], status['last_success_at'], status['consecutive_failures']),
                         ('unconfirmed', None, 0))

    def test_mira_with_a_declared_status_file_confirms_and_skips(self):
        manifest = json.loads((self.mira / 'resident-home.json').read_text())
        manifest['sync_status'] = 'shared/automation/state/sync.json'
        (self.mira / 'resident-home.json').write_text(json.dumps(manifest))
        own = self.mira / 'shared/automation/state/sync.json'
        first = self.run_mira(writes_status(own, 'ok', 0))
        self.assertEqual(first['state'], 'ok')
        self.run_mira(writes_status(own, 'failed', 1, reason='push rejected'))
        skipped = self.run_mira(writes_status(own, 'busy', 0))
        self.assertEqual(skipped['last_success_at'], first['last_success_at'])
        self.assertEqual((skipped['state'], skipped['consecutive_failures'], skipped['last_outcome']),
                         ('error', 1, 'skipped'))

    # --- Lume: home_sync.py exits 75 when the lock is held -------------------
    def test_lume_exit_75_after_failure_is_neither_error_nor_success(self):
        first = self.run_lume(writes_status(self.lume_status, 'ok', 0))
        self.assertEqual((first['state'], first['confirmed_by']), ('ok', 'status_file'))
        failed = self.run_lume(writes_status(self.lume_status, 'failed', 1, reason='merge conflict: x'))
        self.assertEqual((failed['state'], failed['consecutive_failures']), ('error', 1))
        self.assertIn('merge conflict: x', failed['last_error'])
        busy = self.run_lume(writes_status(self.lume_status, 'busy', 75))
        self.assertEqual(busy['last_success_at'], first['last_success_at'])
        self.assertEqual((busy['state'], busy['consecutive_failures'], busy['last_outcome']), ('error', 1, 'skipped'))
        self.assertEqual(busy['last_exit_code'], 75)
        again = self.run_lume(writes_status(self.lume_status, 'ok', 0))
        self.assertEqual((again['state'], again['consecutive_failures'], again['last_error']), ('ok', 0, None))

    def test_lume_exit_75_after_success_keeps_success_and_does_not_advance_it(self):
        self.seed()
        busy = self.run_lume(writes_status(self.lume_status, 'busy', 75))
        self.assertEqual((busy['state'], busy['last_success_at'], busy['consecutive_failures']), ('ok', self.T0, 0))
        self.assertIn('last_skip_at', busy)

    def test_exit_75_is_a_skip_even_without_a_fresh_status_file(self):
        self.seed(state='error', consecutive_failures=2, last_error='old')
        busy = self.run_lume(lambda *a, **k: Completed(75))
        self.assertEqual((busy['state'], busy['consecutive_failures'], busy['last_success_at'], busy['last_outcome']),
                         ('error', 2, self.T0, 'skipped'))

    def test_repeated_skips_read_as_stale_once_the_last_success_is_old(self):
        from datetime import datetime, timedelta, timezone
        self.seed()
        self.run_lume(writes_status(self.lume_status, 'busy', 75))
        later = datetime.fromisoformat(self.T0) + timedelta(seconds=4 * home_sync_loop.SYNC_INTERVAL_SECS)
        self.assertEqual(home_sync_loop.health(self.status, now=later)['state'], 'stale')

    # --- the status file must come from this run and agree with the exit ----
    def test_an_old_status_file_does_not_confirm_a_new_run(self):
        self.lume_status.parent.mkdir(parents=True)
        self.lume_status.write_text(json.dumps({'status': 'ok', 'checked_at': '2026-09-01T00:00:00+02:00',
                                                'last_success_at': '2026-09-01T00:00:00+02:00'}))
        status = self.run_lume(lambda *a, **k: Completed(0))
        self.assertEqual((status['state'], status['last_success_at'], status['confirmed_by']),
                         ('unconfirmed', None, 'exit_code'))
        self.assertIn('not written by this run', status['note'])

    def test_a_naive_timestamp_does_not_confirm(self):
        from datetime import datetime
        self.lume_status.parent.mkdir(parents=True)
        def runner(*a, **k):
            self.lume_status.write_text(json.dumps({'status': 'ok', 'checked_at': datetime.now().isoformat()}))
            return Completed(0)
        self.assertEqual(self.run_lume(runner)['state'], 'unconfirmed')

    def test_status_that_contradicts_the_exit_code_is_a_failure(self):
        for reported, code, words in (('ok', 1, 'contradicts'), ('busy', 1, 'contradicts'),
                                      ('ok', 75, 'contradicts'), ('mystery', 0, 'not recognised')):
            with self.subTest(reported=reported, code=code):
                status = self.run_lume(writes_status(self.lume_status, reported, code))
                self.assertEqual(status['state'], 'error')
                self.assertIn(words, status['last_error'])

    def test_refused_is_a_failure(self):
        status = self.run_lume(writes_status(self.lume_status, 'refused', 1, reason='detached HEAD'))
        self.assertEqual((status['state'], status['consecutive_failures']), ('error', 1))
        self.assertIn('refused', status['last_error'])

    def test_resident_success_time_is_normalised_to_utc(self):
        from datetime import datetime, timezone
        status = self.run_lume(writes_status(self.lume_status, 'ok', 0))
        self.assertEqual(datetime.fromisoformat(status['last_success_at']).utcoffset().total_seconds(), 0)

    # --- the declared status path is validated like every other home path --
    def test_sync_status_path_is_validated(self):
        (self.outside / 'status.json').write_text('{}')
        (self.lume / 'link').symlink_to(self.outside)
        (self.lume / 'adir').mkdir()
        for bad in ('/tmp/status.json', '../outside/status.json', 'automation/../../outside/x.json',
                    'link/status.json', 'adir', '', 7):
            with self.subTest(bad=bad):
                manifest = json.loads((self.lume / 'resident-home.json').read_text())
                manifest['sync_status'] = bad
                (self.lume / 'resident-home.json').write_text(json.dumps(manifest))
                with self.lume_env(), self.assertRaises(ValueError):
                    imported_home.validate()
                with self.assertRaises(ValueError):
                    imported_home.sync_status_path(self.lume, manifest)

    def test_status_path_may_not_exist_yet(self):
        with self.lume_env():
            root, manifest = imported_home.validate()
        self.assertEqual(imported_home.sync_status_path(root, manifest), self.lume / LUME_SYNC_STATUS)
        self.assertIsNone(imported_home.sync_status_path(root, {}))


class _quiet:
    def __enter__(self):
        logging.disable(logging.CRITICAL)
    def __exit__(self, *exc):
        logging.disable(logging.NOTSET)


class HookImportCheckTest(HomeFixture):
    """Chaos 47.8 imports <root>/.chaos/hooks.json into its database once and
    never reads it again. Before that import, the file the manifest names must
    be the file Chaos imports, and must be importable."""

    def setUp(self):
        super().setUp()
        self.chaos = Path(self.tmp.name) / 'chaos-home';self.chaos.mkdir()
        self.hooks = MiraManifestCompatibilityTest.hooks()

    def check(self, hooks=None, manifest=None):
        if hooks is not None:
            (self.lume / '.chaos/hooks.json').write_text(json.dumps(hooks))
        manifest = manifest or json.loads((self.lume / 'resident-home.json').read_text())
        return imported_home.check_hook_import_source(self.lume, manifest, self.chaos)

    def test_mira_current_hooks_are_importable(self):
        self.assertEqual(self.check(self.hooks), 'ready to import')

    def test_after_the_import_the_check_is_a_no_op(self):
        (self.chaos / 'house-hooks-v1.json').write_text('{}')
        self.assertEqual(self.check({'hooks': {'UserPromptSubmit': []}}), 'already imported')

    def test_manifest_must_name_the_file_chaos_imports(self):
        (self.lume / 'other.json').write_text(json.dumps(self.hooks))
        manifest = json.loads((self.lume / 'resident-home.json').read_text())
        manifest['hooks'] = 'other.json'
        with self.assertRaisesRegex(ValueError, 'the file Chaos imports'):
            self.check(manifest=manifest)

    def test_shapes_chaos_would_reject_fail_here_with_a_reason(self):
        command = {'type': 'command', 'command': 'true'}
        bad = {
            'extra top-level key': {'hooks': {}, 'version': 1},
            'unknown event': {'hooks': {'UserPromptSubmit': [{'hooks': [command]}]}},
            'stop matcher': {'hooks': {'Stop': [{'matcher': 'x', 'hooks': [command]}]}},
            'prompt handler': {'hooks': {'Stop': [{'hooks': [{'type': 'prompt'}]}]}},
            'unknown handler field': {'hooks': {'Stop': [{'hooks': [dict(command, shell='bash')]}]}},
            'blank command': {'hooks': {'Stop': [{'hooks': [dict(command, command=' ')]}]}},
            'zero timeout': {'hooks': {'Stop': [{'hooks': [dict(command, timeout=0)]}]}},
            'long timeout': {'hooks': {'Stop': [{'hooks': [dict(command, timeout=601)]}]}},
            'unknown group field': {'hooks': {'Stop': [{'hooks': [command], 'when': 'x'}]}},
        }
        for name, hooks in bad.items():
            with self.subTest(name):
                with self.assertRaises(ValueError):
                    self.check(hooks)

    def test_stock_house_hooks_in_the_global_source_are_refused(self):
        self.check(self.hooks)
        (self.chaos / 'hooks.json').write_text(json.dumps({'_helixkit_managed': 'hosted-agent-stop-journal-reflex:v2', 'hooks': {}}))
        with self.assertRaisesRegex(ValueError, 'stock house hooks'):
            self.check()
        (self.chaos / 'hooks.json').write_text(json.dumps({'hooks': {}}))
        self.assertEqual(self.check(), 'ready to import')

    def test_cli_runs_validation_then_the_import_check(self):
        (self.lume / '.chaos/hooks.json').write_text(json.dumps(self.hooks))
        env = {'SOULSHOUSE_HOME_PROFILE': 'portable_v1', 'SOULSHOUSE_HOME_ROOT': str(self.lume),
               'SOULSHOUSE_PORTABLE_HOME_ID': 'test-lume', 'CHAOS_HOME': str(self.chaos)}
        run = lambda: subprocess.run([sys.executable, str(RUNTIME / 'imported_home.py'), '--hook-import-check'],
                                     env={**os.environ, **env}, capture_output=True, text=True)
        self.assertEqual(run().stdout.strip(), 'imported home hooks: ready to import')
        (self.lume / '.chaos/hooks.json').write_text(json.dumps({'hooks': {'SessionStart': [], 'BeforeTurn': [],
                                                                           'Stop': [], 'Notification': []}}))
        result = run()
        self.assertEqual(result.returncode, 1)
        self.assertIn('may only use', result.stderr)

    def test_entrypoint_imports_hooks_the_same_way_for_every_imported_profile(self):
        text = (RUNTIME / 'entrypoint.sh').read_text()
        check = text.index('imported_home.py --hook-import-check')
        provision = text.index('gosu agent python3 /usr/local/share/helixkit-agent/runtime_hooks.py')
        self.assertLess(check, provision)
        self.assertLess(text.index('fi # stock memory installation'), provision)
        self.assertNotIn('mira_v1', text[check - 400:provision + 80])
        self.assertIn('if [ "$HOME_CLASS" = "imported" ]; then\n    gosu agent python3 /home/agent/imported_home.py --hook-import-check',
                      text)


if __name__ == '__main__':
    unittest.main()
