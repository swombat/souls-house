"""Offline subprocess regression tests for trigger-local Telegram correlation.

Run: python3 -m unittest discover -s test/runtime -p 'telegram_*_test.py'
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from unittest.mock import patch


class TelegramRunCorrelationTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        fake_chaos = root / "fake-chaos"
        # A real subprocess, not a mocked subprocess.run: report only synthetic
        # runtime identifiers actually delivered through exec's environment.
        fake_chaos.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "sys.stdin.read()\n"
            "print(json.dumps({k: v for k, v in os.environ.items() "
            "if k.startswith(('SOULSHOUSE_RUNTIME_', 'HELIXKIT_RUNTIME_'))}))\n"
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
            "SOULSHOUSE_RUNTIME_RUN_ID": "stale-run",
            "SOULSHOUSE_RUNTIME_CHAT_ID": "stale-chat",
            "SOULSHOUSE_RUNTIME_TELEGRAM_THREAD_ID": "stale-thread",
        }
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, self.environment, clear=True).start()
        spec = importlib.util.spec_from_file_location(
            "telegram_correlation_shim",
            Path(__file__).resolve().parents[2] / "agent-runtime" / "trigger_shim.py"
        )
        self.shim = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.shim)
        # Match the existing Ruby shim tests: no Flask server or request context.
        patch.object(self.shim, "jsonify", side_effect=lambda body: body).start()
        patch.object(self.shim, "graph_memory_notice", return_value=None).start()
        self.observed = []

        def dispatch(*args, **kwargs):
            self.assertIsNone(self.shim._activity_context.reporter)
            self.observed.append(getattr(self.shim._activity_context, "telegram_run", None))
            return self.run_child()

        patch.object(self.shim, "legacy_trigger", side_effect=dispatch).start()
        patch.object(self.shim, "persistent_trigger", side_effect=dispatch).start()

    def run_child(self):
        result = self.shim.run_chaos(
            "synthetic-model", 10, "synthetic prompt", False, provider="openai",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def trigger(self, **overrides):
        payload = {
            "session_id": "synthetic-session",
            "request": "synthetic request",
            "trigger_kind": "telegram",
            "runtime_run_id": "run-current",
            "conversation_id": "thread-current",
        }
        payload.update(overrides)
        with patch.object(self.shim, "request", types.SimpleNamespace(
            headers={"Authorization": "Bearer synthetic-trigger-token"},
            get_json=lambda silent=True: payload,
        )):
            return self.shim.trigger()

    def assert_cleaned_up(self):
        self.assertIsNone(self.shim._activity_context.telegram_run)
        self.assertIsNone(self.shim._activity_context.reporter)
        self.assertIsNone(self.shim._activity_context.turn_deadline)
        self.assertFalse(self.shim._activity_context.memory_aggregation)
        self.assertFalse(self.shim._running_sessions)
        lock = self.shim._lock_for("synthetic-session")
        self.assertTrue(lock.acquire(blocking=False))
        lock.release()
        # A child's environment must never be constructed by mutating ours.
        for key, value in self.environment.items():
            self.assertEqual(os.environ[key], value)

    def test_telegram_subprocess_environment_and_next_turn_are_isolated(self):
        for persistent in (False, True):
            with self.subTest(persistent=persistent):
                first = self.trigger(persistent_session=persistent)
                self.assertEqual(first, {
                    "SOULSHOUSE_RUNTIME_RUN_ID": "run-current",
                    "SOULSHOUSE_RUNTIME_TELEGRAM_THREAD_ID": "thread-current",
                })
                self.assertEqual(self.observed[-1], ("run-current", "thread-current"))
                self.assert_cleaned_up()
                second = self.trigger(
                    trigger_kind="scheduled", runtime_run_id="unrelated",
                    conversation_id="unrelated", persistent_session=persistent,
                )
                self.assertEqual(second, {})
                self.assertIsNone(self.observed[-1])
                self.assert_cleaned_up()
                self.assertEqual(self.run_child(), {})

    def test_next_telegram_turn_gets_only_its_own_identifiers(self):
        self.trigger()
        self.assertEqual(self.trigger(runtime_run_id="run-next", conversation_id="thread-next"), {
            "SOULSHOUSE_RUNTIME_RUN_ID": "run-next",
            "SOULSHOUSE_RUNTIME_TELEGRAM_THREAD_ID": "thread-next",
        })
        self.assert_cleaned_up()

    def test_missing_run_id_never_inherits_stale_identifiers(self):
        self.assertEqual(self.trigger(runtime_run_id=None), {})
        self.assert_cleaned_up()

    def test_exception_cleans_context_before_next_invocation(self):
        def failing_dispatch(*args, **kwargs):
            self.assertEqual(self.run_child()["SOULSHOUSE_RUNTIME_RUN_ID"], "run-current")
            raise RuntimeError("synthetic dispatch failure")

        with patch.object(self.shim, "legacy_trigger", side_effect=failing_dispatch):
            with self.assertRaisesRegex(RuntimeError, "synthetic dispatch failure"):
                self.trigger()
        self.assert_cleaned_up()
        self.assertEqual(self.trigger(trigger_kind="scheduled"), {})

    def test_cancellable_subprocess_path_gets_same_invocation_environment(self):
        # Exercise the real Popen path used by async turns, not only subprocess.run.
        with patch.object(self.shim._activity_context, "cancel_event", threading.Event(), create=True):
            self.assertEqual(self.trigger(), {
                "SOULSHOUSE_RUNTIME_RUN_ID": "run-current",
                "SOULSHOUSE_RUNTIME_TELEGRAM_THREAD_ID": "thread-current",
            })
            self.assert_cleaned_up()
            self.assertEqual(self.trigger(trigger_kind="scheduled"), {})

    def test_inherited_legacy_identifiers_cannot_leak_to_uncorrelated_turn(self):
        with patch.dict(os.environ, {
            "HELIXKIT_RUNTIME_RUN_ID": "legacy-stale-run",
            "HELIXKIT_RUNTIME_CHAT_ID": "legacy-stale-chat",
            "HELIXKIT_RUNTIME_TELEGRAM_THREAD_ID": "legacy-stale-thread",
        }):
            self.assertEqual(self.trigger(trigger_kind="scheduled"), {})
            self.assert_cleaned_up()

    def test_instrumented_response_echoes_only_current_telegram_run(self):
        output = "\n".join(json.dumps(event) for event in [
            {"type": "process.started", "process_id": "synthetic-process"},
            {"type": "item.completed", "item": {
                "type": "agent_message", "text": "Diagnostic output, not a reply.",
            }},
        ])
        result = subprocess.CompletedProcess(["synthetic-chaos"], 0, output, "")
        events = self.shim.parse_events(output)

        def respond(*args, **kwargs):
            return self.shim.instrumented_response(
                session_id="synthetic-session",
                result=result,
                events=events,
                invocation_text="synthetic prompt",
                usage={},
                runtime={"provider": "openai", "model": "synthetic-model"},
                session={"outcome": "legacy_fresh"},
                prompt={"mode": "full"},
                resumed=False,
                fresh_fallback=False,
                roll=None,
            )

        with patch.object(self.shim, "legacy_trigger", side_effect=respond):
            for run_id in ["run-current", "run-next"]:
                with self.subTest(run_id=run_id):
                    response, status = self.trigger(runtime_run_id=run_id)
                    self.assertEqual(status, 200)
                    self.assertEqual(response["telegram_delivery_run_id"], run_id)
                    self.assertEqual(response["chaos_session_id"], "synthetic-process")
                    self.assertEqual(response["stdout"], "Diagnostic output, not a reply.")
                    self.assert_cleaned_up()

            for overrides in [
                {"trigger_kind": "scheduled"},
                {"runtime_run_id": None},
            ]:
                with self.subTest(overrides=overrides):
                    response, status = self.trigger(**overrides)
                    self.assertEqual(status, 200)
                    self.assertNotIn("telegram_delivery_run_id", response)
                    self.assert_cleaned_up()

        # Also call the actual presenter after trigger cleanup, with no context.
        response, status = respond()
        self.assertEqual(status, 200)
        self.assertNotIn("telegram_delivery_run_id", response)


if __name__ == "__main__":
    unittest.main()
