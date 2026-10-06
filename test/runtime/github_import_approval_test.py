import importlib.util
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

RUNTIME = Path(__file__).resolve().parents[2] / "agent-runtime"
sys.path.insert(0, str(RUNTIME))
import github_import_approval as guard
import github_import_credential as helper


class ManagedImportTest(unittest.TestCase):
    def test_legacy_homes_never_call_approval(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertFalse(guard.check(lambda: self.fail("must not fetch")))

    def test_live_approval_matches_configuration_before_any_git_or_home_code(self):
        env = {
            "SOULSHOUSE_GITHUB_IMPORT_ID": "12",
            "SOULSHOUSE_GITHUB_IMPORT_FINGERPRINT": "opaque",
            "SOULSHOUSE_GITHUB_IMPORT_REPOSITORY": "owner/home",
            "SOULSHOUSE_GITHUB_IMPORT_BRANCH": "main",
            "SOULSHOUSE_PORTABLE_HOME_ID": "identity",
        }
        approved = {"approved": True, "import_id": "12", "credential_fingerprint": "opaque",
                    "repository": "owner/home", "branch": "main", "portable_home_id": "identity",
                    "home_profile": "portable_v1"}
        with patch.dict(os.environ, env, clear=True), patch.object(guard.imported_home, "validate", return_value=(Path("/home"), {"identity_id": "identity"})), patch.object(guard.subprocess, "run") as run:
            with self.assertRaises(ValueError):
                guard.check(lambda: {**approved, "credential_fingerprint": "changed"})
            run.assert_not_called()
            self.assertTrue(guard.check(lambda: approved))
            self.assertEqual(run.call_count, 3)
            args = [call.args[0] for call in run.call_args_list]
            self.assertIn("https://github.com/owner/home.git", args[0])
            self.assertNotIn("opaque", repr(args))

    def test_credential_helper_only_returns_explicit_connection_and_repository(self):
        services = {"services": [{"provider": "github", "connection_id": "svc_12",
                                 "credentials": {"token": "github_pat_synthetic"}}]}
        request = {"protocol": "https", "host": "github.com", "path": "owner/home.git"}
        self.assertEqual(helper.credentials(request, services, "svc_12", "owner/home"),
                         {"username": "x-access-token", "password": "github_pat_synthetic"})
        for wrong in ({**request, "host": "evil.example"}, {**request, "path": "other/home.git"},
                      {**request, "protocol": "http"}):
            self.assertIsNone(helper.credentials(wrong, services, "svc_12", "owner/home"))
        self.assertIsNone(helper.credentials(request, services, "svc_other", "owner/home"))

    def test_standard_policy_and_strategy_must_match_server_before_any_git(self):
        config = {'auto_commit_paths': ['notes'], 'append_only_paths': ['notes']}
        env = {
            'SOULSHOUSE_HOME_PROFILE': 'portable_v1', 'SOULSHOUSE_HOME_SYNC_STRATEGY': 'standard',
            'SOULSHOUSE_HOME_SYNC_CONFIGURATION': json.dumps(config),
            'SOULSHOUSE_GITHUB_IMPORT_ID': '12', 'SOULSHOUSE_GITHUB_IMPORT_FINGERPRINT': 'opaque',
            'SOULSHOUSE_GITHUB_IMPORT_REPOSITORY': 'owner/home',
            'SOULSHOUSE_GITHUB_IMPORT_BRANCH': 'main', 'SOULSHOUSE_PORTABLE_HOME_ID': 'identity'}
        approved = {'approved': True, 'import_id': '12', 'credential_fingerprint': 'opaque',
                    'repository': 'owner/home', 'branch': 'main', 'portable_home_id': 'identity',
                    'home_profile': 'portable_v1', 'sync_strategy': 'standard', 'sync_configuration': config}
        with patch.dict(os.environ, env, clear=True), \
                patch.object(guard.imported_home, 'validate', return_value=(Path('/home'), {'identity_id': 'identity'})), \
                patch.object(guard.subprocess, 'run') as run:
            for changed in ({'sync_strategy': 'existing'}, {'sync_configuration': {'auto_commit_paths': ['private']}}):
                with self.assertRaises(ValueError):
                    guard.check(lambda: {**approved, **changed})
                run.assert_not_called()
            self.assertTrue(guard.check(lambda: approved))

    def test_guard_precedes_hook_import_and_sync_start(self):
        text = (RUNTIME / "entrypoint.sh").read_text()
        self.assertLess(text.index("github_import_approval.py"), text.index("runtime_hooks.py"))
        self.assertLess(text.index("github_import_approval.py"), text.index("home_sync_loop.py"))

    def test_operator_helper_requires_live_approval_before_interactive_chaos(self):
        text = (RUNTIME / "github-import-trust-setup").read_text()
        self.assertIn("${SOULSHOUSE_GITHUB_IMPORT_ID:?", text)
        self.assertIn("set -eu", text)
        self.assertLess(text.index("github_import_approval.py"), text.index("runtime_settings.py"))
        self.assertLess(text.index("github_import_approval.py"), text.index("exec gosu agent chaos"))


if __name__ == "__main__":
    unittest.main()
