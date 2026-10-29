import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('runtime_hooks', Path(__file__).resolve().parents[1] / 'agent-runtime/runtime_hooks.py')
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)


class RuntimeHooksTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / 'home'
        self.project = Path(self.tmp.name) / 'repo'
        self.home.mkdir()
        (self.project / '.chaos').mkdir(parents=True)
        (self.home / 'hooks.json').write_text(json.dumps({'_helixkit_managed': 'hosted-agent-stop-journal-reflex:v2', 'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'true'}]}]}}))
        (self.project / '.chaos/hooks.json').write_text(json.dumps({'_helixkit_managed': 'hosted-agent-stop-journal-reflex:v2', 'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'true'}]}]}}))
        self.rows, self.calls = [], []

    def run_cli(self, home, project, *args):
        self.calls.append(args)
        if args == ('list',):
            return json.dumps(self.rows)
        if args[1] == 'import':
            self.rows.append({'id': args[4] + '-1'})
        return ''

    def prepare(self):
        s.prepare(self.home, self.project, self.run_cli)

    def test_once_then_no_replay_even_after_resident_changes(self):
        self.prepare()
        self.assertEqual(len([c for c in self.calls if c[1:2] == ('enable',)]), 2)
        record = json.loads((self.home / s.MANIFEST).read_text())
        self.assertEqual(record['status'], 'complete')
        self.assertEqual((self.home / s.MANIFEST).stat().st_mode & 0o777, 0o600)
        # Simulate deletion, disabling, revocation, and later legacy file changes.
        self.rows = []
        (self.project / '.chaos/hooks.json').write_text('not active configuration')
        self.calls = []
        self.prepare()
        self.assertEqual(self.calls, [])

    def test_collision_does_not_mutate(self):
        self.rows = [{'id': 'house-project-v1-1'}]
        with self.assertRaisesRegex(RuntimeError, 'collision'):
            self.prepare()
        self.assertEqual(self.calls, [('list',)])
        self.assertFalse((self.home / s.MANIFEST).exists())

    def test_interrupted_enable_is_never_replayed(self):
        def fail(home, project, *args):
            if args[1:2] == ('enable',):
                raise RuntimeError('interrupted')
            return self.run_cli(home, project, *args)
        with self.assertRaisesRegex(RuntimeError, 'interrupted'):
            s.prepare(self.home, self.project, fail)
        self.calls = []
        with self.assertRaisesRegex(RuntimeError, 'operator review'):
            self.prepare()
        # Only a read: an import that got as far as a house row is never replayed.
        self.assertEqual(self.calls, [('list',)])

    def test_import_that_never_started_is_retried_not_latched(self):
        # #641: the first import was rejected before any row existed. The
        # pending manifest held nothing, so every later boot crash-looped.
        def reject(home, project, *args):
            if args[1:2] == ('import',):
                self.calls.append(args)
                raise RuntimeError('Chaos hook provisioning failed')
            return self.run_cli(home, project, *args)
        with self.assertRaisesRegex(RuntimeError, 'provisioning failed'):
            s.prepare(self.home, self.project, reject)
        self.assertEqual(json.loads((self.home / s.MANIFEST).read_text())['status'], 'pending')
        self.calls = []
        self.prepare()
        self.assertEqual(json.loads((self.home / s.MANIFEST).read_text())['status'], 'complete')
        self.assertEqual(len([c for c in self.calls if c[1:2] == ('enable',)]), 2)

    def test_underscore_keys_are_stripped_from_the_import_copy_only(self):
        source = self.home / 'hooks.json'
        original = json.dumps({'_note': 'kept by the resident', '_helixkit_managed': 'x',
                               'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'true'}]}]}})
        source.write_text(original)
        self.prepare()
        copy = json.loads((self.home / 'house-global-v1-import.json').read_text())
        self.assertEqual(set(copy), {'hooks'})
        self.assertEqual(source.read_text(), original)

    def test_invalid_source_fails_before_mutation(self):
        path = self.project / '.chaos/hooks.json'
        path.write_text('{broken')
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(path.read_text(), '{broken')
        self.assertEqual(self.calls, [])

    def test_manifest_cannot_be_reused_for_another_project(self):
        self.prepare()
        with self.assertRaisesRegex(RuntimeError, 'does not match'):
            s.prepare(self.home, self.home, self.run_cli)




class HouseTrustTest(unittest.TestCase):
    SCHEMA = ('CREATE TABLE project_trust (project_path TEXT PRIMARY KEY NOT NULL, '
              'trust_level TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)')

    def setUp(self):
        import sqlite3
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / 'home'
        self.project = Path(self.tmp.name) / 'repo'
        self.home.mkdir()
        self.project.mkdir()
        self.db = self.home / 'chaos.sqlite'
        sqlite3.connect(str(self.db)).execute(self.SCHEMA)

    def rows(self):
        import sqlite3
        return sqlite3.connect(str(self.db)).execute('SELECT project_path, trust_level FROM project_trust').fetchall()

    def test_grants_the_workspace_once(self):
        self.assertEqual(s.ensure_house_trust(self.home, self.project), 'granted')
        self.assertEqual(self.rows(), [(str(self.project.resolve()), 'trusted')])
        self.assertEqual(s.ensure_house_trust(self.home, self.project), 'trusted')
        self.assertEqual(len(self.rows()), 1)

    def test_never_overrides_a_resident_untrusting_their_workspace(self):
        import sqlite3
        db = sqlite3.connect(str(self.db))
        db.execute('INSERT INTO project_trust VALUES (?, ?, 1, 1)', (str(self.project.resolve()), 'untrusted'))
        db.commit()
        self.assertEqual(s.ensure_house_trust(self.home, self.project), 'untrusted')
        self.assertEqual(self.rows(), [(str(self.project.resolve()), 'untrusted')])

    def test_unknown_schema_writes_nothing(self):
        import sqlite3
        db = sqlite3.connect(str(self.db))
        db.execute('DROP TABLE project_trust')
        db.execute('CREATE TABLE project_trust (project_path TEXT PRIMARY KEY, trust_level TEXT)')
        db.commit()
        with self.assertRaisesRegex(RuntimeError, 'schema'):
            s.ensure_house_trust(self.home, self.project)
        self.assertEqual(sqlite3.connect(str(self.db)).execute('SELECT * FROM project_trust').fetchall(), [])

    def test_no_database_yet_is_skipped(self):
        self.db.unlink()
        self.assertIn('skipped', s.ensure_house_trust(self.home, self.project))

    def test_entrypoint_creates_house_oauth_home_before_provisioning(self):
        text = (Path(s.__file__).with_name('entrypoint.sh')).read_text()
        mk = text.index('mkdir -p "$CHAOS_HOME/oauth-runtime"')
        self.assertIn('if [ "$HOME_CLASS" != "imported" ]; then', text[mk - 120:mk])
        self.assertLess(mk, text.index('runtime_settings.py\n'))
        self.assertLess(mk, text.index('runtime_hooks.py\n'))
        self.assertLess(text.index('HOME_CLASS="$('), mk)

    def test_entrypoint_grants_only_for_house_homes(self):
        text = (Path(s.__file__).with_name('entrypoint.sh')).read_text()
        block = text[text.index('runtime_hooks.py --house-trust') - 200:text.index('runtime_hooks.py --house-trust')]
        self.assertIn('if [ "$HOME_CLASS" != "imported" ]; then', block)

@unittest.skipUnless(__import__('os').environ.get('CHAOS_TEST_BIN'), 'set CHAOS_TEST_BIN for real binary tests')
class RealRuntimeHooksTest(unittest.TestCase):
    def test_actual_import_disable_delete_and_restart(self):
        import os
        from unittest.mock import patch
        config_spec = importlib.util.spec_from_file_location('runtime_settings', Path(s.__file__).with_name('runtime_settings.py'))
        config = importlib.util.module_from_spec(config_spec)
        config_spec.loader.exec_module(config)
        with tempfile.TemporaryDirectory() as td, patch.dict(os.environ, {'CHAOS_BIN': os.environ['CHAOS_TEST_BIN']}):
            home, project = Path(td) / 'home', Path(td) / 'repo'
            (project / '.chaos').mkdir(parents=True)
            source = project / '.chaos/hooks.json'
            source.write_text(json.dumps({'_helixkit_managed': 'hosted-agent-stop-journal-reflex:v2', 'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'true'}]}]}}))
            config.prepare(home)
            s.prepare(home, project)
            rows = json.loads(s.command(home, project, 'list'))
            self.assertEqual(len(rows), 1)
            self.assertTrue(rows[0]['enabled'])
            self.assertTrue(rows[0]['approved'])
            ident = rows[0]['id']
            s.command(home, project, '--yes', 'disable', ident)
            s.prepare(home, project)
            self.assertEqual(json.loads(s.command(home, project, 'list'))[0]['inactive_reason'], 'disabled')
            s.command(home, project, '--yes', 'remove', ident)
            s.prepare(home, project)
            self.assertEqual(json.loads(s.command(home, project, 'list')), [])

    def test_actual_project_hook_runs_only_once_workspace_is_trusted(self):
        import os
        import subprocess
        from unittest.mock import patch
        config_spec = importlib.util.spec_from_file_location('runtime_settings', Path(s.__file__).with_name('runtime_settings.py'))
        config = importlib.util.module_from_spec(config_spec)
        config_spec.loader.exec_module(config)
        with tempfile.TemporaryDirectory() as td, patch.dict(os.environ, {'CHAOS_BIN': os.environ['CHAOS_TEST_BIN']}):
            home, project = Path(td) / 'home', Path(td) / 'repo'
            (project / '.chaos').mkdir(parents=True)
            subprocess.run(['git', 'init', '-q', str(project)], check=True)
            (project / '.chaos/hooks.json').write_text(json.dumps({'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'true'}]}]}}))
            config.prepare(home)
            s.prepare(home, project)
            before = json.loads(s.command(home, project, 'list'))[0]['inactive_reason']
            self.assertIn('not trusted', before or '')
            self.assertEqual(s.ensure_house_trust(home, project), 'granted')
            self.assertIsNone(json.loads(s.command(home, project, 'list'))[0]['inactive_reason'])

    def test_actual_global_hooks_with_a_resident_note_import(self):
        """#641, Claude's home: a global hooks.json with a top-level `_note`.
        The real import schema rejects that key; the import copy must not
        carry it, and the migration completes."""
        import os
        from unittest.mock import patch
        config_spec = importlib.util.spec_from_file_location('runtime_settings', Path(s.__file__).with_name('runtime_settings.py'))
        config = importlib.util.module_from_spec(config_spec)
        config_spec.loader.exec_module(config)
        with tempfile.TemporaryDirectory() as td, patch.dict(os.environ, {'CHAOS_BIN': os.environ['CHAOS_TEST_BIN']}):
            home, project = Path(td) / 'home', Path(td) / 'repo'
            (project / '.chaos').mkdir(parents=True)
            oauth = home / 'oauth-runtime'
            oauth.mkdir(parents=True)
            source = home / 'hooks.json'
            source.write_text(json.dumps({'_note': 'resident bookkeeping', 'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'true'}]}]}}))
            config.prepare(oauth)
            s.prepare(oauth, project, global_source=source)
            self.assertEqual(json.loads((oauth / s.MANIFEST).read_text())['status'], 'complete')
            rows = json.loads(s.command(oauth, project, 'list'))
            self.assertEqual([r['enabled'] for r in rows if r['id'].startswith('house-global-v1-')], [True])
    def test_fresh_birth_then_first_subscription_turn_has_trusted_hooks(self):
        """No oauth-runtime before boot. Boot as the entrypoint does for a house
        home; the subscription home the shim then selects already has settings,
        the project hook and trust, before its first turn."""
        import os
        import subprocess
        from unittest.mock import patch
        config_spec = importlib.util.spec_from_file_location('runtime_settings', Path(s.__file__).with_name('runtime_settings.py'))
        config = importlib.util.module_from_spec(config_spec)
        config_spec.loader.exec_module(config)
        with tempfile.TemporaryDirectory() as td:
            home, project = Path(td) / 'home', Path(td) / 'repo'
            (project / '.chaos').mkdir(parents=True)
            subprocess.run(['git', 'init', '-q', str(project)], check=True)
            (project / '.chaos/hooks.json').write_text(json.dumps({'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'true'}]}]}}))
            home.mkdir()
            self.assertFalse((home / 'oauth-runtime').exists())
            env = {'CHAOS_BIN': os.environ['CHAOS_TEST_BIN'], 'CHAOS_HOME': str(home), 'AGENT_REPO_PATH': str(project)}
            with patch.dict(os.environ, env):
                (home / 'oauth-runtime').mkdir()          # entrypoint, house homes
                config.main()                              # runtime_settings.py
                s.main()                                   # runtime_hooks.py
                with patch.object(s.sys, 'argv', ['runtime_hooks.py', '--house-trust']):
                    s.main()
            oauth = home / 'oauth-runtime'                 # what _oauth_account_env selects
            with patch.dict(os.environ, {'CHAOS_BIN': os.environ['CHAOS_TEST_BIN']}):
                rows = json.loads(s.command(oauth, project, 'list'))
            project_rows = [r for r in rows if r['definition'].get('project')]
            self.assertTrue(project_rows)
            for row in project_rows:
                self.assertTrue(row['enabled'])
                self.assertIsNone(row['inactive_reason'])


if __name__ == '__main__':
    unittest.main()
