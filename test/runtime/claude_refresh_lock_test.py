"""Claude subscription sign-ins survive a refresh-lock collision (#816).

The house no longer starts `claude auth status` to read a sign-in (it is a
second refresher), and a subscription run that fails on authentication before
doing anything is retried once after Claude Code's refresh lock clears.

Run: python3 -m unittest discover -s test/runtime -p 'claude_refresh_lock_test.py'
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


AUTH_FAILURE = "\n".join([
    json.dumps({"type": "process.started", "process_id": "p1"}),
    json.dumps({"type": "turn.started"}),
    json.dumps({"type": "item.completed", "item": {"id": "item_0", "type": "error",
                                                    "message": "Recall requires a PostgreSQL VFS mount with pgvector"}}),
    json.dumps({"type": "error", "message": "clamp_auth_unavailable: Claude Code subscription authentication is unavailable"}),
    json.dumps({"type": "turn.failed", "error": {"message": "clamp_auth_unavailable: Claude Code subscription authentication is unavailable"}}),
]) + "\n"

SUCCESS = "\n".join([
    json.dumps({"type": "process.started", "process_id": "p2"}),
    json.dumps({"type": "item.completed", "item": {"id": "item_1", "type": "agent_message", "text": "hello"}}),
    json.dumps({"type": "turn.completed", "usage": {}}),
]) + "\n"


class ClaudeRefreshLockTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.claude_dir = self.root / "claude"
        self.claude_dir.mkdir()
        self.calls = self.root / "calls"
        self.script = self.root / "script.json"
        fake_chaos = self.root / "fake-chaos"
        # Plays the scripted outputs in order and records each invocation.
        fake_chaos.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "sys.stdin.read()\n"
            f"calls = {str(self.calls)!r}\n"
            "n = sum(1 for _ in open(calls)) if os.path.exists(calls) else 0\n"
            "open(calls, 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n"
            f"steps = json.load(open({str(self.script)!r}))\n"
            "out, code = steps[min(n, len(steps) - 1)]\n"
            "sys.stdout.write(out)\n"
            "sys.exit(code)\n"
        )
        fake_chaos.chmod(0o755)
        fake_claude = self.root / "fake-claude"
        fake_claude.write_text(f"#!{sys.executable}\nimport sys\nsys.exit(97)\n")
        fake_claude.chmod(0o755)
        environment = {
            "HOME": str(self.root),
            "PATH": os.defpath,
            "PYTHONDONTWRITEBYTECODE": "1",
            "TRIGGER_BEARER_TOKEN": "synthetic-trigger-token",
            "CHAOS_BIN": str(fake_chaos),
            "CLAUDE_BIN": str(fake_claude),
            "CHAOS_HOME": str(self.root / "chaos"),
            "CLAUDE_CONFIG_DIR": str(self.claude_dir),
            "AGENT_IDENTITY_PATH": str(self.root / "identity"),
            "AGENT_REPO_PATH": str(self.root),
        }
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, environment, clear=True).start()
        spec = importlib.util.spec_from_file_location(
            "claude_refresh_lock_shim",
            Path(__file__).resolve().parents[2] / "agent-runtime" / "trigger_shim.py"
        )
        self.shim = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.shim)

    def write_credentials(self, **overrides):
        oauth = {"accessToken": "synthetic-access", "refreshToken": "synthetic-refresh",
                 "expiresAt": int((time.time() + 3600) * 1000), "subscriptionType": "max"}
        oauth.update(overrides)
        (self.claude_dir / ".credentials.json").write_text(json.dumps({"claudeAiOauth": oauth}))

    def script_runs(self, *steps):
        self.script.write_text(json.dumps(list(steps)))

    def invocations(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def hold_lock(self, age_secs=0):
        lock = self.claude_dir / self.shim.CLAUDE_REFRESH_LOCK
        lock.mkdir(exist_ok=True)
        stamp = time.time() - age_secs
        os.utime(lock, (stamp, stamp))
        return lock

    def run_subscription(self, **kwargs):
        return self.shim.run_chaos("claude-opus-5-5", 60, "prompt", True, provider="anthropic",
                                   auth_mode="oauth_account", **kwargs)

    # Reading a sign-in starts no Claude Code process.

    def test_status_reads_the_files_and_starts_no_claude_process(self):
        self.write_credentials()
        (self.claude_dir / ".claude.json").write_text(json.dumps({"oauthAccount": {"emailAddress": "someone@example.test"}}))
        with patch.object(self.shim.subprocess, "run", side_effect=AssertionError("started a process")):
            status = self.shim._anthropic_account_status()
        self.assertEqual(status, {"status": "connected", "provider": "anthropic",
                                  "email": "someone@example.test", "plan": "max"})

    def test_status_is_none_without_a_refreshable_sign_in(self):
        self.assertEqual(self.shim._anthropic_account_status()["status"], "none")
        self.write_credentials(refreshToken="")
        self.assertEqual(self.shim._anthropic_account_status()["status"], "none")
        self.write_credentials(refreshTokenExpiresAt=int((time.time() - 60) * 1000))
        self.assertEqual(self.shim._anthropic_account_status()["status"], "none")
        (self.claude_dir / ".credentials.json").write_text("{not json")
        self.assertEqual(self.shim._anthropic_account_status()["status"], "none")

    def test_status_ignores_an_expired_access_token_that_can_still_be_refreshed(self):
        self.write_credentials(expiresAt=int((time.time() - 60) * 1000),
                               refreshTokenExpiresAt=int((time.time() + 86400) * 1000))
        self.assertEqual(self.shim._anthropic_account_status()["status"], "connected")

    # The retry.

    def test_an_auth_failure_before_work_is_retried_once_after_the_lock_clears(self):
        self.write_credentials()
        self.script_runs([AUTH_FAILURE, 1], [SUCCESS, 0])
        lock = self.hold_lock()
        sleeps = []

        def sleep(seconds):
            sleeps.append(seconds)
            lock.rmdir()  # the other refresher finishes

        with patch.object(self.shim.time, "sleep", side_effect=sleep):
            # The lock is held before the first attempt, so the first wait
            # clears it; hold it again as if another refresh began.
            original = self.shim._run_chaos_once

            def once(*args, **kwargs):
                result = original(*args, **kwargs)
                if len(self.invocations()) == 1:
                    self.hold_lock()
                return result

            with patch.object(self.shim, "_run_chaos_once", side_effect=once):
                result = self.run_subscription()
        self.assertEqual(result.returncode, 0)
        self.assertIn("agent_message", result.stdout)
        self.assertEqual(len(self.invocations()), 2)
        self.assertEqual(len(sleeps), 2)

    def test_a_second_auth_failure_is_returned_for_rails_to_mark_expired(self):
        self.write_credentials()
        self.script_runs([AUTH_FAILURE, 1], [AUTH_FAILURE, 1], [SUCCESS, 0])
        result = self.run_subscription(resume_id="session-1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("clamp_auth_unavailable", result.stdout)
        calls = [json.loads(line) for line in self.invocations()]
        self.assertEqual(len(calls), 2)
        self.assertTrue(all(call[-3:] == ["resume", "session-1", "-"] for call in calls))

    def test_no_retry_once_the_model_has_done_anything(self):
        partial = SUCCESS.replace('"turn.completed"', '"turn.ignored"') + AUTH_FAILURE
        self.script_runs([partial, 1], [SUCCESS, 0])
        result = self.run_subscription()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(self.invocations()), 1)

    def test_no_retry_off_the_claude_subscription(self):
        self.script_runs([AUTH_FAILURE, 1], [SUCCESS, 0])
        self.shim.run_chaos("claude-opus-5-5", 60, "prompt", True, provider="anthropic", auth_mode="api_key")
        self.shim.run_chaos("gpt", 60, "prompt", True, provider="openai", auth_mode="oauth_account")
        self.assertEqual(len(self.invocations()), 2)

    def test_other_failures_are_not_retried(self):
        self.script_runs(['{"type": "turn.failed", "error": {"message": "rate limit"}}\n', 1], [SUCCESS, 0])
        self.assertEqual(self.run_subscription().returncode, 1)
        self.assertEqual(len(self.invocations()), 1)

    # Waiting for the lock.

    def test_no_wait_without_a_lock_or_with_an_abandoned_one(self):
        with patch.object(self.shim.time, "sleep", side_effect=AssertionError("waited")):
            self.assertLess(self.shim.await_claude_refresh_lock(30), 1)
            self.hold_lock(age_secs=self.shim.CLAUDE_REFRESH_LOCK_STALE_SECS + 5)
            self.assertLess(self.shim.await_claude_refresh_lock(30), 1)

    def test_the_wait_is_bounded_by_the_budget(self):
        self.hold_lock()
        now = [0.0]

        def sleep(seconds):
            now[0] += seconds
            self.hold_lock()  # a live holder keeps touching it

        waited = self.shim.await_claude_refresh_lock(5, sleep=sleep, clock=lambda: now[0])
        self.assertGreaterEqual(waited, 5)
        self.assertLess(waited, 6)

    def test_failure_detection(self):
        completed = subprocess.CompletedProcess
        self.assertTrue(self.shim.clamp_auth_failed_before_work(completed([], 1, AUTH_FAILURE, "")))
        self.assertFalse(self.shim.clamp_auth_failed_before_work(completed([], 0, AUTH_FAILURE, "")))
        self.assertFalse(self.shim.clamp_auth_failed_before_work(completed([], 1, SUCCESS, "")))
        self.assertFalse(self.shim.clamp_auth_failed_before_work(None))


if __name__ == "__main__":
    unittest.main()
