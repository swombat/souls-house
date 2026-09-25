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
    def test_missing_defaults_only_and_boot_order(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            (home/'config.toml').write_text('storage_url="sqlite:///kept.sqlite"\n')
            calls = []
            def run(home, *args):
                calls.append(args)
                return json.dumps({'agent_compaction_control': 'disabled',
                                   'model_providers': {'gemini': {'name': 'resident custom'}}}) if args == ('get',) else ''
            s.prepare(home, run)
            self.assertEqual(calls[:2], [('migrate', '--dry-run'), ('migrate',)])
            edits = [a for a in calls if a[0] == 'set']
            self.assertEqual([a[1] for a in edits], ['model_providers.openrouter'])
            self.assertEqual(calls[-1], ('doctor',))
            self.assertEqual(tomllib.loads((home/'config.toml').read_text()), {'storage_url':'sqlite:///kept.sqlite'})

    def test_environment_storage_is_preserved_as_a_reference(self):
        with tempfile.TemporaryDirectory() as td, patch.dict(os.environ, {"CHAOS_STORAGE_URL":"postgres://private"}):
            calls = []
            def run(home, *args):
                calls.append(args)
                return '{}' if args == ('get',) else ''
            s.prepare(Path(td), run)
            self.assertIn(('bootstrap', 'set', 'storage_url', 'env:CHAOS_STORAGE_URL'), calls)
            self.assertNotIn('postgres://private', str(calls))

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
        self.env = patch.dict(os.environ, {'CHAOS_BIN':os.environ['CHAOS_TEST_BIN']})
        self.env.start();self.addCleanup(self.env.stop)

    def read(self):
        return json.loads(s.command(self.home, 'get'))

    def test_fresh_and_second_boot(self):
        s.prepare(self.home)
        first = self.read()
        self.assertEqual(first['agent_compaction_control'], 'bounded')
        self.assertEqual(set(first['model_providers']), {'gemini','openrouter'})
        s.prepare(self.home)
        self.assertEqual(self.read(), first)
        self.assertEqual(set(tomllib.loads((self.home/'config.toml').read_text())), {'storage_url'})

    def test_legacy_choices_custom_provider_and_second_boot(self):
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
