"""A failed run carries the runtime's own reason, redacted and bounded (#843)."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


CLAUDE_SIGN_IN_FAILURES = (
    "clamp_runtime_failed: Claude Code reported a failed result: Failed to authenticate: [redacted], "
    "or use `claude setup-token` and set CLAUDE_CODE_OAUTH_TOKEN for unattended jobs",
    "clamp_runtime_failed: control request failed: Unable to validate model: "
    "OAuth refresh token is no longer valid; run /login to re-authenticate",
)


class RuntimeFailureTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {
            "HOME": str(root),
            "PATH": os.defpath,
            "PYTHONDONTWRITEBYTECODE": "1",
            "TRIGGER_BEARER_TOKEN": "synthetic-trigger-token",
            "CHAOS_HOME": str(root / "chaos"),
            "AGENT_IDENTITY_PATH": str(root / "identity"),
            "AGENT_REPO_PATH": str(root),
        }, clear=True).start()
        spec = importlib.util.spec_from_file_location(
            "runtime_failure_shim",
            Path(__file__).resolve().parents[2] / "agent-runtime" / "trigger_shim.py",
        )
        self.shim = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.shim)
        patch.object(self.shim, "jsonify", side_effect=lambda body: body).start()

    def respond(self, returncode, events, stderr="", *, provider="gemini"):
        stdout = "\n".join(json.dumps(event) for event in events)
        result = subprocess.CompletedProcess(["synthetic-chaos"], returncode, stdout, stderr)
        with self.assertLogs(self.shim.log, level="INFO") as logs:
            response, status = self.shim.instrumented_response(
                session_id="synthetic-session",
                result=result,
                events=self.shim.parse_events(stdout),
                invocation_text="synthetic prompt",
                usage={},
                runtime={"provider": provider, "model": "synthetic-model"},
                session={"outcome": "legacy_fresh"},
                prompt={"mode": "full"},
                resumed=False,
                fresh_fallback=False,
                roll=None,
            )
        return response, status, "\n".join(logs.output)

    def test_failed_run_names_the_runtime_error_and_logs_it(self):
        message = ("antigravity_runtime_failed: Antigravity invocation failed with status ERROR; "
                   'result detail: {"error":{"code":503,"message":"model overloaded"}}')
        response, status, logs = self.respond(1, [
            {"type": "error", "message": message},
            {"type": "turn.failed", "error": {"message": message}},
        ])
        self.assertEqual(status, 500)
        self.assertEqual(response["runtime_failure"], {
            "code": "antigravity_runtime_failed",
            "message": 'Antigravity invocation failed with status ERROR; '
                       'result detail: {"error":{"code":503,"message":"model overloaded"}}',
        })
        self.assertIn("runtime_failure=antigravity_runtime_failed: Antigravity invocation failed", logs)

    def test_claude_sign_in_failures_set_auth_expired_on_the_response(self):
        for message in CLAUDE_SIGN_IN_FAILURES:
            with self.subTest(message=message):
                response, status, _logs = self.respond(
                    1, [{"type": "error", "message": message}], provider="anthropic"
                )
                self.assertEqual(status, 500)
                self.assertEqual(response.get("error_kind"), "auth_expired")

    def test_quoting_claude_sign_in_failures_in_stdout_is_not_auth_expiry(self):
        for message in CLAUDE_SIGN_IN_FAILURES:
            with self.subTest(message=message):
                response, _status, _logs = self.respond(1, [
                    {"type": "item.completed", "item": {"type": "agent_message", "text": message}},
                    {"type": "error", "message": "unrelated runtime failure"},
                ], provider="anthropic")
                self.assertIn(message, response["stdout"])
                self.assertNotIn("error_kind", response)

    def test_cloudflare_challenge_takes_precedence_over_claude_sign_in_failure(self):
        response, _status, _logs = self.respond(
            1, [{"type": "error", "message": CLAUDE_SIGN_IN_FAILURES[0]}],
            stderr="Failed to authenticate. API Error: 403 Attention Required! | Cloudflare",
            provider="anthropic",
        )
        self.assertEqual(response.get("error_kind"), "provider_challenge")

    def test_stderr_is_the_fallback_and_secrets_are_redacted(self):
        stderr = ("thread 'main' panicked at provider.rs:12\n"
                  "request to https://example.test/v1?key=AIzaSyA0123456789abcdefghijklmnop failed\n"
                  "Authorization: Bearer abcdefghijklmnop.qrstuvwx for someone@example.com\n"
                  "api_key=sk-live-0123456789abcdef\n")
        response, _status, logs = self.respond(101, [], stderr)
        failure = response["runtime_failure"]
        self.assertEqual(failure["code"], "runtime_error")
        self.assertIn("panicked at provider.rs:12", failure["message"])
        for secret in ("AIzaSy", "abcdefghijklmnop", "someone@example.com", "sk-live", "key=AIza"):
            self.assertNotIn(secret, failure["message"])
            self.assertNotIn(secret, logs)

    def test_quoted_secret_values_are_redacted_whole(self):
        cases = {
            '{"client_secret":"synthetic-secret"}': ("synthetic-secret",),
            '{"token":"synthetic-short-token"}': ("synthetic-short-token",),
            '{"password":"two secret words"}': ("two", "secret words"),
            '{"password":"a \\"quoted\\" word"}': ("quoted", " word"),
            "refresh_token='two words' tail": ("two words",),
            "api_key=sk-live-012 next": ("sk-live",),
        }
        for text, secrets in cases.items():
            with self.subTest(text=text):
                response, _status, logs = self.respond(1, [{"type": "error", "message": text}])
                message = response["runtime_failure"]["message"]
                self.assertIn("[redacted]", message)
                for secret in secrets:
                    self.assertNotIn(secret, message)
                    self.assertNotIn(secret, logs)
        # Prose about a token is not a token.
        response, _status, _logs = self.respond(1, [{"type": "error", "message": "Token has been expired or revoked"}])
        self.assertEqual(response["runtime_failure"]["message"], "Token has been expired or revoked")

    def test_oversize_reason_is_truncated(self):
        long = "x " * 2000
        response, _status, _logs = self.respond(1, [{"type": "error", "message": long}])
        self.assertEqual(len(response["runtime_failure"]["message"]), self.shim.RUNTIME_FAILURE_LIMIT)
        self.assertTrue(response["runtime_failure"]["message"].endswith("…"))

    def test_successful_run_is_unchanged(self):
        response, status, _logs = self.respond(0, [
            {"type": "process.started", "process_id": "synthetic-process"},
            {"type": "error", "message": "a recovered retry"},
        ])
        self.assertEqual(status, 200)
        self.assertNotIn("runtime_failure", response)


if __name__ == "__main__":
    unittest.main()
