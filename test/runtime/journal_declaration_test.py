"""A stock home may carry a resident-home.json that holds only its journal
declaration (jAdype). That file must not make the home look imported: the
portable-home readers key on SOULSHOUSE_HOME_PROFILE, never on the file."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

RUNTIME = Path(__file__).resolve().parents[2] / 'agent-runtime'
sys.path.insert(0, str(RUNTIME))
import imported_home  # noqa: E402
import runtime_settings  # noqa: E402


class StockHomeJournalDeclarationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve()
        (self.home / 'resident-home.json').write_text(json.dumps({'journal': {'path': 'memory/daily-journals'}}))
        env = patch.dict(os.environ, {'SOULSHOUSE_HOME_PROFILE': 'house', 'AGENT_IDENTITY_PATH': str(self.home),
                                      'SOULSHOUSE_HOME_ROOT': str(self.home)})
        env.start()
        self.addCleanup(env.stop)

    def test_the_home_stays_a_house_home(self):
        self.assertFalse(imported_home.enabled())
        self.assertEqual('house', imported_home.home_class())
        with self.assertRaisesRegex(ValueError, 'house residents have no imported home'):
            imported_home.validate(self.home)

    def test_protected_context_is_the_house_files_not_the_manifest(self):
        reasons = []
        files = runtime_settings.protected_files(report=reasons.append)
        self.assertEqual([str(self.home / name) for name in runtime_settings.HOUSE_PROTECTED_FILES], files)
        self.assertEqual([], reasons)

    def test_the_sync_loop_starts_only_for_an_imported_class(self):
        entrypoint = (RUNTIME / 'entrypoint.sh').read_text()
        start = entrypoint.index('home_sync_loop.py &')
        guard = entrypoint.rindex('if [', 0, start)
        self.assertIn('"$HOME_CLASS" = "imported"', entrypoint[guard:start])

    def test_the_identity_fingerprint_leaves_the_file_out(self):
        import importlib.util
        os.environ.setdefault('TRIGGER_BEARER_TOKEN', 'test-token')
        spec = importlib.util.spec_from_file_location('journal_declaration_shim', RUNTIME / 'trigger_shim.py')
        shim = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(shim)
        self.assertNotIn('resident-home.json', shim.IDENTITY_FINGERPRINT_FILES)


class ImportedHomeJournalDeclarationTest(unittest.TestCase):
    """A portable home that declares its journal still validates as before."""

    def test_the_journal_key_does_not_disturb_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            manifest = {'format': 'souls-home/v1', 'profile': 'mira_v1', 'identity_id': 'test-mira', 'graph': 'external',
                        'journal': {'path': 'shared/memory/daily-journals'}, 'hooks': 'hooks.json'}
            for key in ('instructions', 'soul', 'narrative', 'journal_reader'):
                manifest[key] = key + '.md'
                (root / manifest[key]).write_text('text')
            (root / 'hooks.json').write_text(json.dumps({'hooks': {k: [{}] for k in ('SessionStart', 'BeforeTurn', 'Stop')}}))
            (root / 'resident-home.json').write_text(json.dumps(manifest))
            with patch.dict(os.environ, {'MIRA_ROOT': str(root), 'SOULSHOUSE_HOME_PROFILE': 'mira_v1',
                                         'SOULSHOUSE_PORTABLE_HOME_ID': 'test-mira'}), \
                    patch.object(imported_home, 'sync_script', return_value=root / 'sync.py'):
                self.assertEqual(root, imported_home.validate()[0])


if __name__ == '__main__':
    unittest.main()
