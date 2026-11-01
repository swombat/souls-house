import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest
from unittest.mock import patch

RUNTIME = Path(__file__).resolve().parents[1] / 'agent-runtime'
spec = importlib.util.spec_from_file_location('runtime_settings', RUNTIME / 'runtime_settings.py')
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)


class RuntimeConfigTest(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {"SOULSHOUSE_APP_URL": "", "HELIXKIT_APP_URL": ""})
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_house_provider_uses_scoped_resident_bearer_not_upstream_key(self):
        with tempfile.TemporaryDirectory() as td, patch.dict(os.environ, {"SOULSHOUSE_APP_URL": "http://house.test"}):
            calls = []
            def run(home, *args):
                calls.append(args)
                return '{}' if args == ('get',) else ''
            s.prepare(Path(td), run)
            settings = json.loads(next(a[2] for a in calls if a[:2] == ('set', 'model_providers.house')))
            self.assertEqual(settings['base_url'], 'http://house.test/api/v1/house_inference')
            self.assertEqual(settings['env_key'], 'SOULSHOUSE_BEARER_TOKEN')
            self.assertEqual(settings['wire_api'], 'chat_completions')
            self.assertNotIn('HOUSE_INFERENCE_OPENROUTER_API_KEY', str(calls))

    def test_missing_defaults_only_and_boot_order(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            (home/'config.toml').write_text('storage_url="sqlite:///kept.sqlite"\n')
            calls = []
            def run(home, *args):
                calls.append(args)
                if args == ('--help',):
                    return 'Commands:\n  bootstrap  Inspect\n  migrate    Import legacy TOML\n  get  Inspect\n'
                return json.dumps({'agent_compaction_control': 'disabled', 'hook_approval_policy': 'on-request',
                                   'model_auto_compact_token_limit': 123456, 'protected_context_files': [],
                                   'model_providers': {'gemini': {'name': 'resident custom'}}}) if args == ('get',) else ''
            s.prepare(home, run)
            self.assertEqual(calls[:3], [('--help',), ('migrate', '--dry-run'), ('migrate',)])
            edits = [a for a in calls if a[0] == 'set']
            self.assertEqual([a[1] for a in edits], ['model_providers.openrouter'])
            self.assertEqual(calls[-1], ('doctor',))
            self.assertEqual(tomllib.loads((home/'config.toml').read_text()), {'storage_url':'sqlite:///kept.sqlite'})

    def test_binary_without_migrate_skips_it(self):
        # seuros/chaos#110 removed `config migrate` with the TOML layers.
        with tempfile.TemporaryDirectory() as td:
            calls = []
            def run(home, *args):
                calls.append(args)
                if args == ('--help',):
                    return 'Commands:\n  bootstrap  Inspect\n  doctor  Diagnose\n  get  Inspect\n'
                return '{}' if args == ('get',) else ''
            s.prepare(Path(td), run)
            self.assertNotIn('migrate', [a[0] for a in calls])
            self.assertEqual(calls[-1], ('doctor',))

    def test_environment_storage_is_preserved_as_a_reference(self):
        with tempfile.TemporaryDirectory() as td, patch.dict(os.environ, {"CHAOS_STORAGE_URL":"postgres://private"}):
            calls = []
            def run(home, *args):
                calls.append(args)
                return '{}' if args == ('get',) else ''
            s.prepare(Path(td), run)
            self.assertIn(('bootstrap', 'set', 'storage_url', 'env:CHAOS_STORAGE_URL'), calls)
            self.assertIn(('set', 'hook_approval_policy', '"automatic"'), calls)
            self.assertNotIn('postgres://private', str(calls))

    def _sets(self, current='{}', env=None):
        with tempfile.TemporaryDirectory() as td, patch.dict(os.environ, env or {}):
            calls = []
            def run(home, *args):
                calls.append(args)
                return current if args == ('get',) else ''
            s.prepare(Path(td), run)
            return {a[1]: json.loads(a[2]) for a in calls if a[0] == 'set'}

    def test_compaction_defaults_for_a_house_home(self):
        sets = self._sets(env={'SOULSHOUSE_HOME_PROFILE': '', 'AGENT_IDENTITY_PATH': '/home/agent/identity'})
        self.assertEqual(sets['model_auto_compact_token_limit'], 400000)
        self.assertEqual(sets['protected_context_files'],
                         ['/home/agent/identity/soul.md', '/home/agent/identity/self-narrative.md'])

    def test_explicit_compaction_choices_are_kept(self):
        # An empty protected list is an opt-out, not an absence.
        current = json.dumps({'model_auto_compact_token_limit': 90000, 'protected_context_files': []})
        sets = self._sets(current, env={'SOULSHOUSE_HOME_PROFILE': ''})
        self.assertNotIn('model_auto_compact_token_limit', sets)
        self.assertNotIn('protected_context_files', sets)

    def _imported(self, manifest):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        root = Path(td.name).resolve()
        (root/'resident-home.json').write_text(json.dumps(manifest))
        return root, {'SOULSHOUSE_HOME_PROFILE': 'portable_v1', 'SOULSHOUSE_HOME_ROOT': str(root)}

    def test_imported_home_protects_its_own_soul_and_narrative(self):
        root, env = self._imported({'soul': 'soul.md', 'narrative': 'self-narrative.md'})
        self.assertEqual(self._sets(env=env)['protected_context_files'],
                         [str(root/'soul.md'), str(root/'self-narrative.md')])

    def test_imported_home_declaration_wins_including_empty(self):
        root, env = self._imported({'soul': 'soul.md', 'narrative': 'n.md',
                                    'protected_context': ['soul.md', 'n.md', 'memory/MEMORY.md']})
        self.assertEqual(self._sets(env=env)['protected_context_files'],
                         [str(root/'soul.md'), str(root/'n.md'), str(root/'memory/MEMORY.md')])
        root, env = self._imported({'soul': 'soul.md', 'narrative': 'n.md', 'protected_context': []})
        self.assertEqual(self._sets(env=env)['protected_context_files'], [])

    def test_unresolvable_imported_home_leaves_the_key_absent(self):
        for manifest in [{'soul': '../outside.md', 'narrative': 'n.md'},
                         {'soul': '/etc/passwd', 'narrative': 'n.md'},
                         {'protected_context': 'soul.md'}]:
            with self.subTest(manifest=manifest):
                _, env = self._imported(manifest)
                sets = self._sets(env=env)
                self.assertNotIn('protected_context_files', sets)
                self.assertEqual(sets['model_auto_compact_token_limit'], 400000)
        sets = self._sets(env={'SOULSHOUSE_HOME_PROFILE': 'portable_v1', 'SOULSHOUSE_HOME_ROOT': '/nonexistent-home'})
        self.assertNotIn('protected_context_files', sets)

    def test_failure_does_not_expose_command_output(self):
        result = subprocess.CompletedProcess([], 1, 'private settings', 'secret token')
        with patch.object(s.subprocess, 'run', return_value=result):
            with self.assertRaises(RuntimeError) as error:
                s.command(Path('/tmp/fixture'), 'migrate')
        self.assertNotIn('secret', str(error.exception))
        self.assertNotIn('private settings', str(error.exception))

    def test_entrypoint_prepares_as_agent_before_account_commands(self):
        text = (RUNTIME/'entrypoint.sh').read_text()
        pos = text.index('gosu agent python3 /usr/local/share/helixkit-agent/runtime_settings.py')
        self.assertLess(pos, text.index('register_provider_key()'))
        self.assertLess(pos, text.index('gosu agent chaos_journald'))
        self.assertNotIn('CHAOS_DEFAULTS', text)
        self.assertNotIn('cat >> "$CHAOS_CONFIG"', text)

    def test_existing_oauth_home_is_prepared_but_not_created(self):
        with tempfile.TemporaryDirectory() as td, patch.dict(os.environ, {'CHAOS_HOME':td}):
            with patch.object(s, 'prepare') as prepare:
                s.main()
                self.assertEqual(prepare.call_count, 1)
            (Path(td)/'oauth-runtime').mkdir()
            with patch.object(s, 'prepare') as prepare:
                s.main()
                self.assertEqual(prepare.call_count, 2)


@unittest.skipUnless(os.environ.get('CHAOS_TEST_BIN'), 'set CHAOS_TEST_BIN for real SQLite migration tests')
class RealRuntimeConfigTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.env = patch.dict(os.environ, {'CHAOS_BIN':os.environ['CHAOS_TEST_BIN'], 'SOULSHOUSE_APP_URL': '', 'HELIXKIT_APP_URL': ''})
        self.env.start();self.addCleanup(self.env.stop)

    def read(self):
        return json.loads(s.command(self.home, 'get'))

    def test_fresh_and_second_boot(self):
        with patch.dict(os.environ, {'SOULSHOUSE_HOME_PROFILE': '', 'AGENT_IDENTITY_PATH': '/fixture/identity'}):
            s.prepare(self.home)
            first = self.read()
            s.prepare(self.home)
        self.assertEqual(first['agent_compaction_control'], 'bounded')
        self.assertEqual(first['model_auto_compact_token_limit'], 400000)
        self.assertEqual(first['protected_context_files'],
                         ['/fixture/identity/soul.md', '/fixture/identity/self-narrative.md'])
        self.assertEqual(set(first['model_providers']), {'gemini','openrouter'})
        self.assertEqual(self.read(), first)
        self.assertEqual(set(tomllib.loads((self.home/'config.toml').read_text())), {'storage_url'})

    def test_resident_choices_survive_repeated_boots_in_both_homes(self):
        oauth = self.home/'oauth-runtime'
        oauth.mkdir()
        with patch.dict(os.environ, {'CHAOS_HOME': str(self.home), 'SOULSHOUSE_HOME_PROFILE': ''}):
            s.main()
            for home in (self.home, oauth):
                s.command(home, 'set', 'protected_context_files', '[]')
                s.command(home, 'set', 'model_auto_compact_token_limit', '150000')
            s.main()
            s.main()
        for home in (self.home, oauth):
            with self.subTest(home=home.name):
                settings = json.loads(s.command(home, 'get'))
                self.assertEqual(settings['protected_context_files'], [])
                self.assertEqual(settings['model_auto_compact_token_limit'], 150000)

    def test_legacy_choices_custom_provider_and_second_boot(self):
        # Only binaries that still import legacy TOML settings (before seuros/chaos#110).
        if not s.offers_migrate(self.home, s.command):
            self.skipTest('this Chaos has no config migrate; legacy TOML import is gone')
        for choice in ['disabled','bounded']:
            with self.subTest(choice=choice):
                home = self.home/choice;home.mkdir()
                (home/'config.toml').write_text(f'agent_compaction_control="{choice}"\n[model_providers.gemini]\nname="Custom"\nbase_url="https://example.test/v1"\nwire_api="chat_completions"\n')
                s.prepare(home)
                first = json.loads(s.command(home,'get'))
                self.assertEqual(first['agent_compaction_control'],choice)
                self.assertEqual(first['model_providers']['gemini']['name'],'Custom')
                s.prepare(home)
                self.assertEqual(json.loads(s.command(home,'get')),first)

    def test_invalid_config_is_not_overwritten(self):
        p=self.home/'config.toml';p.write_text('[broken\n')
        with self.assertRaises(RuntimeError):s.prepare(self.home)
        self.assertEqual(p.read_text(),'[broken\n')


if __name__ == '__main__':unittest.main()
