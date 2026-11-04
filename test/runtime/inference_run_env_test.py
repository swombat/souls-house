"""The run identity for house inference calls reaches chaos exec per invocation (#678).

Run: python3 -m unittest discover -s test/runtime -p 'inference_run_*_test.py'
"""

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


class InferenceRunEnvTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        fake_chaos = root / "fake-chaos"
        # A real subprocess reports what actually arrived in exec's environment.
        fake_chaos.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "sys.stdin.read()\n"
            "print(json.dumps(os.environ.get('SOULSHOUSE_INFERENCE_RUN')))\n"
        )
        fake_chaos.chmod(0o755)
        self.environment = {
            "HOME": str(root),
            "PATH": os.defpath,
            "PYTHONDONTWRITEBYTECODE": "1",
            "TRIGGER_BEARER_TOKEN": "synthetic-trigger-token",
            "CHAOS_BIN": str(fake_chaos),
            "CHAOS_HOME": str(root / "chaos"),
            "AGENT_IDENTITY_PATH": str(root / "identity"),
            "AGENT_REPO_PATH": str(root),
            # A stale value in the shim's own environment must never leak.
            "SOULSHOUSE_INFERENCE_RUN": "999",
        }
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, self.environment, clear=True).start()
        spec = importlib.util.spec_from_file_location(
            "inference_run_shim",
            Path(__file__).resolve().parents[2] / "agent-runtime" / "trigger_shim.py"
        )
        self.shim = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.shim)
        patch.object(self.shim, "jsonify", side_effect=lambda body: body).start()
        patch.object(self.shim, "graph_memory_notice", return_value=None).start()

        def dispatch(*args, **kwargs):
            result = self.shim.run_chaos("synthetic-model", 10, "synthetic prompt", False, provider="house")
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

        patch.object(self.shim, "legacy_trigger", side_effect=dispatch).start()
        patch.object(self.shim, "persistent_trigger", side_effect=dispatch).start()

    def trigger(self, **overrides):
        payload = {"session_id": "synthetic-session", "request": "synthetic request", "trigger_kind": "wake"}
        payload.update(overrides)
        with patch.object(self.shim, "request", types.SimpleNamespace(
            headers={"Authorization": "Bearer synthetic-trigger-token"},
            get_json=lambda silent=True: payload,
        )):
            return self.shim.trigger()

    def test_each_invocation_gets_only_its_own_run(self):
        for persistent in (False, True):
            with self.subTest(persistent=persistent):
                self.assertEqual(self.trigger(inference_run="41", persistent_session=persistent), "41")
                self.assertEqual(self.trigger(inference_run="42", persistent_session=persistent), "42")
                # No run named: nothing, not the previous run and not the stale env.
                self.assertIsNone(self.trigger(persistent_session=persistent))
                self.assertIsNone(self.shim._activity_context.inference_run)
                self.assertEqual(os.environ["SOULSHOUSE_INFERENCE_RUN"], "999")

    def test_a_value_that_is_not_a_run_id_is_dropped(self):
        for value in ("abc", "1; rm -rf /", "", None, 12.5):
            with self.subTest(value=value):
                self.assertIsNone(self.trigger(inference_run=value))


if __name__ == "__main__":
    unittest.main()
