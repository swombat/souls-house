"""A paid-fallback turn gets no paid provider key (#690).

The house gateway meters every call of a fallback turn against the owner's
cap. A subagent or tool that switched provider inside that turn would spend
the owner's key (or another) off that route, so no paid key reaches the
invocation. Ordinary turns keep theirs.

Run: python3 -m unittest discover -s test/runtime -p 'paid_fallback_*_test.py'
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

KEYS = ("OPENROUTER_API_KEY", "GEMINI_API_KEY", "MOONSHOT_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "XAI_API_KEY")


class PaidFallbackEnvTest(unittest.TestCase):
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
            f"print(json.dumps(sorted(k for k in {list(KEYS)!r} if k in os.environ)))\n"
        )
        fake_chaos.chmod(0o755)
        environment = {
            "HOME": str(root), "PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1",
            "TRIGGER_BEARER_TOKEN": "synthetic-trigger-token", "CHAOS_BIN": str(fake_chaos),
            "CHAOS_HOME": str(root / "chaos"), "AGENT_IDENTITY_PATH": str(root / "identity"),
            "AGENT_REPO_PATH": str(root),
        }
        environment.update({key: "sk-synthetic" for key in KEYS})
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, environment, clear=True).start()
        spec = importlib.util.spec_from_file_location(
            "paid_fallback_shim", Path(__file__).resolve().parents[2] / "agent-runtime" / "trigger_shim.py"
        )
        self.shim = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.shim)
        patch.object(self.shim, "jsonify", side_effect=lambda body: body).start()
        patch.object(self.shim, "graph_memory_notice", return_value=None).start()
        self.provider = None

        def dispatch(*args, **kwargs):
            result = self.shim.run_chaos("synthetic-model", 10, "synthetic prompt", False, provider=self.provider)
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

        patch.object(self.shim, "legacy_trigger", side_effect=dispatch).start()
        patch.object(self.shim, "persistent_trigger", side_effect=dispatch).start()

    def trigger(self, **overrides):
        payload = {"session_id": "synthetic-session", "request": "synthetic request", "trigger_kind": "conversation"}
        payload.update(overrides)
        self.provider = payload.get("provider")
        with patch.object(self.shim, "request", types.SimpleNamespace(
            headers={"Authorization": "Bearer synthetic-trigger-token"},
            get_json=lambda silent=True: payload,
        )):
            return self.shim.trigger()

    def test_a_paid_fallback_turn_on_the_house_provider_gets_no_paid_key(self):
        for persistent in (False, True):
            with self.subTest(persistent=persistent):
                self.assertEqual(self.trigger(provider="house", paid_fallback=True, persistent_session=persistent), [])
                self.assertFalse(self.shim._activity_context.paid_fallback)

    def test_ordinary_turns_keep_their_keys_and_the_flag_needs_the_house_provider(self):
        self.assertEqual(self.trigger(provider="house"), sorted(KEYS))
        self.assertEqual(self.trigger(provider="openrouter", paid_fallback=True), sorted(KEYS))
        self.assertEqual(self.trigger(provider="house", paid_fallback="true"), sorted(KEYS))
        # The previous turn's flag never carries over.
        self.trigger(provider="house", paid_fallback=True)
        self.assertEqual(self.trigger(provider="house"), sorted(KEYS))


if __name__ == "__main__":
    unittest.main()
