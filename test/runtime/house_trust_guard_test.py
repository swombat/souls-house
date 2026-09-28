"""House trust guard: default off; when on, a house turn fails closed without trust."""
import importlib.util
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

RUNTIME = Path(__file__).resolve().parents[2] / 'agent-runtime'
sys.path.insert(0, str(RUNTIME))
import imported_home
os.environ.setdefault("TRIGGER_BEARER_TOKEN", "test-token")
spec = importlib.util.spec_from_file_location('house_trust_shim', RUNTIME / 'trigger_shim.py')
shim = importlib.util.module_from_spec(spec);sys.modules[spec.name] = shim;spec.loader.exec_module(shim)

SWITCH = 'SOULSHOUSE_REQUIRE_HOUSE_TRUST'


class HouseTrustGuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name).resolve()
        self.repo = base / 'repo';self.repo.mkdir()
        self.chaos = base / 'chaos';self.chaos.mkdir()

    def run_house(self, switch=None, provider='anthropic', mode='api_key'):
        env = {'SOULSHOUSE_HOME_PROFILE': 'house', 'CHAOS_HOME': str(self.chaos)}
        if switch is not None:
            env[SWITCH] = switch
        with patch.dict(os.environ, env), patch.object(shim, 'AGENT_REPO_PATH', self.repo), \
                patch.object(shim, 'CHAOS_HOME', self.chaos), patch.object(shim, 'OAUTH_CHAOS_HOME', self.chaos), \
                patch.object(shim, 'CLAUDE_CONFIG_DIR', self.chaos / 'claude'), \
                patch.object(shim.subprocess, 'run') as run:
            shim.run_chaos('test-model', 30, 'request', True, provider=provider, auth_mode=mode)
        return run

    def trust(self, level):
        with sqlite3.connect(self.chaos / 'chaos.sqlite') as db:
            db.execute('CREATE TABLE IF NOT EXISTS project_trust(project_path TEXT, trust_level TEXT)')
            db.execute('DELETE FROM project_trust')
            db.execute('INSERT INTO project_trust VALUES(?,?)', (str(self.repo), level))

    def test_off_by_default_and_never_reads_trust(self):
        self.assertFalse(shim.house_trust_required(environ={}))
        for switch in (None, '0', 'false', ''):
            with self.subTest(switch=switch), patch.object(imported_home, 'check_project_trust', side_effect=AssertionError('trust read')):
                self.run_house(switch=switch).assert_called_once()

    def test_on_fails_closed_without_a_trust_database(self):
        with self.assertRaises(ValueError) as caught:
            self.run_house(switch='1')
        self.assertIn('trust the resident workspace', str(caught.exception))

    def test_on_fails_closed_when_workspace_is_untrusted_or_missing(self):
        self.trust('untrusted')
        with self.assertRaises(ValueError):
            self.run_house(switch='1')
        with sqlite3.connect(self.chaos / 'chaos.sqlite') as db:
            db.execute('DELETE FROM project_trust')
        with self.assertRaises(ValueError) as caught:
            self.run_house(switch='1')
        self.assertIn('memory hooks would not run', str(caught.exception))

    def test_on_allows_a_trusted_workspace_on_every_auth_path(self):
        self.trust('trusted')
        for provider, mode in (('anthropic', 'api_key'), ('anthropic', 'oauth_account')):
            with self.subTest(provider=provider, mode=mode):
                self.run_house(switch='1', provider=provider, mode=mode).assert_called_once()

    def test_no_subprocess_when_refused(self):
        env = {'SOULSHOUSE_HOME_PROFILE': 'house', SWITCH: '1', 'CHAOS_HOME': str(self.chaos)}
        with patch.dict(os.environ, env), patch.object(shim, 'AGENT_REPO_PATH', self.repo), \
                patch.object(shim, 'CHAOS_HOME', self.chaos), patch.object(shim.subprocess, 'run') as run:
            with self.assertRaises(ValueError):
                shim.run_chaos('test-model', 30, 'request', True)
            run.assert_not_called()

    def test_imported_trust_messages_are_unchanged(self):
        with self.assertRaises(ValueError) as caught:
            imported_home.require_runtime_trust(self.repo, self.chaos)
        self.assertEqual(str(caught.exception), 'Review and trust the imported root in Chaos before a resident turn')
        self.trust('untrusted')
        with self.assertRaises(ValueError) as caught:
            imported_home.require_runtime_trust(self.repo, self.chaos)
        self.assertEqual(str(caught.exception), 'Imported home is not trusted in Chaos; its wake hooks would not run')


if __name__ == '__main__':
    unittest.main()
