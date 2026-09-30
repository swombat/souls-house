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
        self.assertEqual(self.calls, [])

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


if __name__ == '__main__':
    unittest.main()
