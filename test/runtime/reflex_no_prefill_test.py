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
import types
import unittest
from datetime import datetime, timezone
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
        self.assertEqual(result.stderr, "")

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
    def load_shim(self, root, extra=None):
        environment = {
            "HOME": str(root), "PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1",
            "TRIGGER_BEARER_TOKEN": "synthetic-trigger-token", "CHAOS_BIN": "/bin/true",
            "CHAOS_HOME": str(root / "chaos"), "AGENT_IDENTITY_PATH": str(root / "identity"),
            "AGENT_REPO_PATH": str(root), **(extra or {}),
        }
        with patch.dict(os.environ, environment, clear=True):
            spec = importlib.util.spec_from_file_location("reflex_route_shim", ROOT / "agent-runtime" / "trigger_shim.py")
            shim = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(shim)
        return shim

    def test_the_runtime_log_says_when_the_reflex_skipped(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        shim = self.load_shim(Path(temporary.name))
        trace = Path(temporary.name) / "stop-events.jsonl"
        since = datetime(2026, 11, 5, 10, 0, tzinfo=timezone.utc)
        rows = [
            {"recorded_at": "2026-11-05T09:59:00+00:00", "journal_skipped": "route_refuses_assistant_last"},
            {"recorded_at": "2026-11-05T11:00:01+01:00", "journal_invited": True},
            "not json",
        ]
        trace.write_text("\n".join(r if isinstance(r, str) else json.dumps(r) for r in rows) + "\n")
        with self.assertNoLogs(shim.log, level="WARNING"):
            self.assertEqual(shim.log_reflex_skips(since, trace), 0)
        with trace.open("a") as fh:
            fh.write(json.dumps({"recorded_at": "2026-11-05T11:00:02+01:00", "journal_invited": False,
                                 "journal_skipped": "route_refuses_assistant_last"}) + "\n")
        with self.assertLogs(shim.log, level="WARNING") as logs:
            self.assertEqual(shim.log_reflex_skips(since, trace), 1)
        self.assertIn("route_refuses_assistant_last", logs.output[0])
        self.assertEqual(shim.log_reflex_skips(since, Path(temporary.name) / "missing.jsonl"), 0)

    def test_invalid_utf8_and_a_large_trace_stay_contained(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        shim = self.load_shim(Path(temporary.name))
        trace = Path(temporary.name) / "stop-events.jsonl"
        since = datetime(2026, 11, 5, 10, 0, tzinfo=timezone.utc)
        skip = json.dumps({"recorded_at": "2026-11-05T11:00:02+01:00",
                           "journal_skipped": "route_refuses_assistant_last"}).encode()
        old = json.dumps({"recorded_at": "2026-11-05T09:00:00+00:00",
                          "journal_skipped": "route_refuses_assistant_last"}).encode()
        filler = b"\xff\xfe not utf-8 \x80\n" + old + b"\n"
        trace.write_bytes(filler * (2 * shim.REFLEX_TRACE_TAIL_BYTES // len(filler)) + skip + b"\n")
        with self.assertLogs(shim.log, level="WARNING") as logs:
            self.assertEqual(shim.log_reflex_skips(since, trace), 1)
        self.assertIn("route_refuses_assistant_last", logs.output[0])
        trace.write_bytes(b"\xff\xfe\x80\n")
        self.assertEqual(shim.log_reflex_skips(since, trace), 0)

    def test_a_run_whose_hook_skipped_is_logged_by_the_trigger(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        shim = self.load_shim(root)
        trace = root / "stop-events.jsonl"
        trace.write_text(json.dumps({"recorded_at": "2026-01-01T00:00:00+00:00",
                                     "journal_skipped": "route_refuses_assistant_last"}) + "\n")
        patch.object(shim, "REFLEX_TRACE_PATH", trace).start()
        patch.object(shim, "jsonify", side_effect=lambda body: body).start()
        patch.object(shim, "graph_memory_notice", return_value=None).start()
        self.addCleanup(patch.stopall)

        def hook_skips(*args, **kwargs):  # what the Stop hook writes during the run
            with trace.open("a") as fh:
                fh.write(json.dumps({"recorded_at": datetime.now(timezone.utc).isoformat(),
                                     "journal_skipped": "route_refuses_assistant_last"}) + "\n")
            return {"status": "ok"}

        patch.object(shim, "legacy_trigger", side_effect=hook_skips).start()
        payload = {"session_id": "synthetic-session", "request": "synthetic request", "trigger_kind": "wake"}
        with patch.dict(os.environ, {"TRIGGER_BEARER_TOKEN": "synthetic-trigger-token"}), \
             patch.object(shim, "request", types.SimpleNamespace(
                 headers={"Authorization": "Bearer synthetic-trigger-token"},
                 get_json=lambda silent=True: payload)):
            with self.assertLogs(shim.log, level="WARNING") as logs:
                shim.trigger()
        skipped = [line for line in logs.output if "journal reflex skipped" in line]
        self.assertEqual(len(skipped), 1, logs.output)

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
