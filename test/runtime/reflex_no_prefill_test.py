"""The journal reflex does not invite on a route that refuses prefill (#725).

Run: python3 -m unittest discover -s test/runtime -p 'reflex_no_prefill_test.py'
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
HOOK = ROOT / "agent-runtime" / "stop_journal_reflex.py"


class ReflexNoPrefillTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.identity = Path(temporary.name) / "identity"
        self.identity.mkdir()
        self.trace = self.identity / "memory/automation/state/stop-events.jsonl"

    def run_hook(self, provider, model, **event):
        env = {"PATH": os.defpath, "AGENT_IDENTITY_PATH": str(self.identity), "PYTHONDONTWRITEBYTECODE": "1"}
        if provider is not None:
            env["SOULSHOUSE_ROUTE_PROVIDER"] = provider
        payload = {"session_id": "s", "turn_id": "t", "model": model,
                   "last_assistant_message": "A synthetic reply.", **event}
        result = subprocess.run([sys.executable, str(HOOK)], input=json.dumps(payload),
                                text=True, capture_output=True, env=env)
        rows = [json.loads(line) for line in self.trace.read_text().splitlines()]
        return result, rows[-1]

    def assert_skipped(self, provider, model):
        result, row = self.run_hook(provider, model)
        self.assertEqual(result.returncode, 0, f"{provider} {model} should not invite")
        self.assertFalse(row["journal_invited"])
        self.assertEqual(row["journal_skipped"], "route_refuses_assistant_last")
        self.assertIn("journal reflex skipped", result.stderr)
        self.assertNotIn("REFLECTION CONTINUATION", result.stderr)

    def assert_invited(self, provider, model):
        result, row = self.run_hook(provider, model)
        self.assertEqual(result.returncode, 2, f"{provider} {model} should invite")
        self.assertTrue(row["journal_invited"])
        self.assertNotIn("journal_skipped", row)
        self.assertIn("REFLECTION CONTINUATION", result.stderr)

    def test_anthropic_five_five_on_chat_completions_routes_is_skipped(self):
        self.assert_skipped("house", "house/claude-haiku-5.5")
        self.assert_skipped("openrouter", "anthropic/claude-haiku-5.5")
        self.assert_skipped("openrouter", "anthropic/claude-sonnet-5.5")
        self.assert_skipped("OpenRouter", "anthropic/claude-opus-5.5")

    def test_routes_that_accept_assistant_last_keep_the_invitation(self):
        self.assert_invited("house", "house/deepseek-v4.1-flash")
        self.assert_invited("openrouter", "anthropic/claude-sonnet-4.5")
        self.assert_invited("openrouter", "anthropic/claude-haiku-4.5")
        self.assert_invited("openrouter", "anthropic/claude-opus-4.1")
        self.assert_invited("openrouter", "anthropic/claude-haiku-5.55")
        # Chaos's own Anthropic adapter sends the continuation as a user turn.
        self.assert_invited("anthropic", "claude-haiku-5-5")
        # No provider from the shim (older shim, hand-run hook): default is to invite.
        self.assert_invited(None, "house/claude-haiku-5.5")

    def test_a_turn_that_would_not_be_invited_is_unchanged(self):
        result, row = self.run_hook("house", "house/claude-haiku-5.5", stop_hook_active=True)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(row["journal_invited"])
        self.assertNotIn("journal_skipped", row)
        self.assertEqual(result.stderr, "")


class ShimPassesRouteTest(unittest.TestCase):
    def test_run_chaos_hands_provider_and_model_to_the_hook_environment(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        environment = {
            "HOME": str(root), "PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1",
            "TRIGGER_BEARER_TOKEN": "synthetic-trigger-token", "CHAOS_BIN": "/bin/true",
            "CHAOS_HOME": str(root / "chaos"), "AGENT_IDENTITY_PATH": str(root / "identity"),
            "AGENT_REPO_PATH": str(root), "SOULSHOUSE_ROUTE_PROVIDER": "stale",
        }
        with patch.dict(os.environ, environment, clear=True):
            spec = importlib.util.spec_from_file_location("reflex_route_shim", ROOT / "agent-runtime" / "trigger_shim.py")
            shim = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(shim)
            captured = {}

            def fake_run(args, **kwargs):
                captured.update(kwargs["env"])
                return subprocess.CompletedProcess(args, 0, "", "")

            shim._activity_context.reporter = None
            with patch.object(shim.subprocess, "run", side_effect=fake_run):
                shim.run_chaos("house/claude-haiku-5.5", 5, "prompt", False, provider="house")
        self.assertEqual(captured["SOULSHOUSE_ROUTE_PROVIDER"], "house")
        self.assertEqual(captured["SOULSHOUSE_ROUTE_MODEL"], "house/claude-haiku-5.5")


if __name__ == "__main__":
    unittest.main()
