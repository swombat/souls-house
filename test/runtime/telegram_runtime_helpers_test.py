"""Offline helper tests, included in the normal runtime CI test discovery."""

import contextlib
from email.parser import BytesParser
from email.policy import default
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


def load_helper(name):
    loader = importlib.machinery.SourceFileLoader(
        name, str(Path(__file__).resolve().parents[2] / "agent-runtime" / name)
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


send = load_helper("soulshouse-send-telegram")
quiet = load_helper("soulshouse-quiet-reason")


class TelegramRuntimeHelpersTest(unittest.TestCase):
    def run_cli(self, helper, args, stdin="", env=None):
        # No inherited credentials, runtime IDs, proxies, or other environment.
        environment = {
            "SOULSHOUSE_APP_URL": "https://house.example",
            "SOULSHOUSE_BEARER_TOKEN": "synthetic-token",
        }
        environment.update(env or {})
        output, errors = io.StringIO(), io.StringIO()
        response = io.BytesIO(b'{"ok":true}')
        response.status = 200
        with patch.dict(os.environ, environment, clear=True), \
                patch.object(helper.sys, "argv", [helper.__name__, *args]), \
                patch.object(helper.sys, "stdin", io.StringIO(stdin)), \
                patch.object(helper.NO_REDIRECT_OPENER, "open", return_value=response) as opened, \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            try:
                status = helper.main()
            except SystemExit as error:
                status = error.code
        self.assertNotIn("synthetic-token", output.getvalue() + errors.getvalue())
        request = opened.call_args.args[0] if opened.called else None
        if request:
            self.assertEqual(request.get_header("Authorization"), "Bearer synthetic-token")
            self.assertEqual(request.method, "POST")
        return status, request, errors.getvalue()

    def test_text_send_includes_run_and_normalizes_argument(self):
        status, request, _ = self.run_cli(
            send, ["reader", "hello\\nworld"],
            env={"SOULSHOUSE_RUNTIME_RUN_ID": "run-new", "HELIXKIT_RUNTIME_RUN_ID": "run-old",
                 "SOULSHOUSE_RUNTIME_TELEGRAM_THREAD_ID": "thread-1"},
        )
        self.assertEqual(status, 0)
        self.assertEqual(request.full_url, "https://house.example/api/v1/telegram_messages")
        self.assertEqual(json.loads(request.data), {
            "recipient": "reader", "text": "hello\nworld", "runtime_run_id": "run-new",
        })

    def test_reply_stdin_includes_legacy_run(self):
        status, request, _ = self.run_cli(
            send, ["--reply-to", "thread-1"], stdin="literal\\ntext\n",
            env={"HELIXKIT_RUNTIME_RUN_ID": "run-old",
                 "HELIXKIT_RUNTIME_TELEGRAM_THREAD_ID": "thread-1"},
        )
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(request.data), {
            "reply_to": "thread-1", "text": "literal\\ntext", "runtime_run_id": "run-old",
        })

    def test_send_outside_run_omits_attribution(self):
        status, request, _ = self.run_cli(send, ["all", "update"])
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(request.data), {"recipient": "all", "text": "update"})

    def test_send_from_conversation_run_still_allows_proactive_telegram(self):
        status, request, _ = self.run_cli(
            send, ["all", "update"],
            env={"SOULSHOUSE_RUNTIME_RUN_ID": "conversation-run", "SOULSHOUSE_RUNTIME_CHAT_ID": "chat-1"},
        )
        self.assertEqual(status, 0)
        self.assertNotIn("runtime_run_id", json.loads(request.data))

    def test_reply_to_other_or_missing_runtime_thread_omits_attribution(self):
        for thread_env in [{}, {"SOULSHOUSE_RUNTIME_TELEGRAM_THREAD_ID": "other"}]:
            with self.subTest(thread_env=thread_env):
                status, request, _ = self.run_cli(
                    send, ["--reply-to", "thread-1", "reply"],
                    env={"SOULSHOUSE_RUNTIME_RUN_ID": "run-1", **thread_env},
                )
                self.assertEqual(status, 0)
                self.assertNotIn("runtime_run_id", json.loads(request.data))

    def test_media_attribution_for_recipient_and_reply(self):
        with tempfile.TemporaryDirectory() as directory:
            attachment = Path(directory) / "image.png"
            attachment.write_bytes(b"synthetic-image")
            for destination, expected in [
                (["reader"], {"recipient": "reader"}),
                (["--reply-to", "thread-1"], {"reply_to": "thread-1"}),
            ]:
                for run_env in [
                    {"SOULSHOUSE_RUNTIME_RUN_ID": "run-1",
                     "SOULSHOUSE_RUNTIME_TELEGRAM_THREAD_ID": "thread-1"},
                    {"HELIXKIT_RUNTIME_RUN_ID": "run-1",
                     "HELIXKIT_RUNTIME_TELEGRAM_THREAD_ID": "thread-1"},
                ]:
                    with self.subTest(destination=destination, run_env=run_env):
                        status, request, _ = self.run_cli(
                            send, [*destination, "--attach", str(attachment)],
                            stdin="caption", env=run_env,
                        )
                        self.assertEqual(status, 0)
                        message = BytesParser(policy=default).parsebytes(
                            f"Content-Type: {request.get_header('Content-type')}\r\n\r\n".encode()
                            + request.data
                        )
                        parts = {
                            part.get_param("name", header="content-disposition"): part
                            for part in message.iter_parts()
                        }
                        fields = {name: part.get_payload(decode=True).decode()
                                  for name, part in parts.items() if name != "media"}
                        self.assertEqual(fields, {
                            **expected, "text": "caption", "runtime_run_id": "run-1",
                        })
                        self.assertEqual(parts["media"].get_filename(), "image.png")
                        self.assertEqual(parts["media"].get_payload(decode=True), b"synthetic-image")

    def test_telegram_quiet_with_and_without_reason(self):
        for reason in ["", "  \n", "Nothing to add.\n"]:
            with self.subTest(reason=reason):
                status, request, _ = self.run_cli(
                    quiet, ["--telegram", "thread-1"], stdin=reason,
                    env={"SOULSHOUSE_RUNTIME_RUN_ID": "run-1",
                         "SOULSHOUSE_RUNTIME_TELEGRAM_THREAD_ID": "thread-1",
                         "SOULSHOUSE_RUNTIME_CHAT_ID": "unrelated-web-room"},
                )
                self.assertEqual(status, 0)
                self.assertEqual(request.full_url,
                                 "https://house.example/api/v1/telegram_conversations/thread-1/quiet_reason")
                self.assertEqual(json.loads(request.data), {
                    "runtime_run_id": "run-1", "reason": reason.strip(),
                })

    def test_telegram_quiet_runtime_environment_precedence_and_legacy(self):
        for env, expected in [
            ({"HELIXKIT_RUNTIME_RUN_ID": "old"}, "old"),
            ({"HELIXKIT_RUNTIME_RUN_ID": "old", "SOULSHOUSE_RUNTIME_RUN_ID": "new"}, "new"),
        ]:
            with self.subTest(env=env):
                status, request, _ = self.run_cli(
                    quiet, ["--telegram", "thread-1"],
                    env={**env, "SOULSHOUSE_RUNTIME_TELEGRAM_THREAD_ID": "thread-1"},
                )
                self.assertEqual(status, 0)
                self.assertEqual(json.loads(request.data)["runtime_run_id"], expected)

    def test_telegram_quiet_requires_runtime_run(self):
        status, request, _ = self.run_cli(quiet, ["--telegram", "thread-1"])
        self.assertEqual(status, 64)
        self.assertIsNone(request)

    def test_telegram_quiet_requires_matching_thread(self):
        for thread_env in [{}, {"SOULSHOUSE_RUNTIME_TELEGRAM_THREAD_ID": "other"}]:
            with self.subTest(thread_env=thread_env):
                status, request, _ = self.run_cli(
                    quiet, ["--telegram", "thread-1"],
                    env={"SOULSHOUSE_RUNTIME_RUN_ID": "run-1", **thread_env},
                )
                self.assertEqual(status, 64)
                self.assertIsNone(request)

    def test_quiet_reason_length_limit_for_both_destinations(self):
        for args in [["chat-1"], ["--telegram", "thread-1"]]:
            for length, expected_status in [(500, 0), (501, 66)]:
                with self.subTest(args=args, length=length):
                    status, request, _ = self.run_cli(
                        quiet, args, stdin="x" * length,
                        env={"SOULSHOUSE_RUNTIME_RUN_ID": "run-1",
                             "SOULSHOUSE_RUNTIME_TELEGRAM_THREAD_ID": "thread-1",
                             "SOULSHOUSE_RUNTIME_CHAT_ID": "chat-1"},
                    )
                    self.assertEqual(status, expected_status)
                    self.assertEqual(request is not None, expected_status == 0)

    def test_existing_conversation_path(self):
        status, request, _ = self.run_cli(
            quiet, ["chat-1"], stdin=" Already answered. \n",
            env={"SOULSHOUSE_RUNTIME_RUN_ID": "run-1", "SOULSHOUSE_RUNTIME_CHAT_ID": "chat-1"},
        )
        self.assertEqual(status, 0)
        self.assertEqual(request.full_url,
                         "https://house.example/api/v1/conversations/chat-1/quiet_reason")
        self.assertEqual(json.loads(request.data), {
            "runtime_run_id": "run-1", "reason": "Already answered.",
        })

    def test_existing_conversation_still_rejects_empty_reason(self):
        status, request, _ = self.run_cli(
            quiet, ["chat-1"],
            env={"SOULSHOUSE_RUNTIME_RUN_ID": "run-1", "SOULSHOUSE_RUNTIME_CHAT_ID": "chat-1"},
        )
        self.assertEqual(status, 66)
        self.assertIsNone(request)

    def test_existing_conversation_still_requires_matching_run(self):
        for env in [
            {"SOULSHOUSE_RUNTIME_RUN_ID": "run-1", "SOULSHOUSE_RUNTIME_CHAT_ID": "other"},
            {"SOULSHOUSE_RUNTIME_CHAT_ID": "chat-1"},
            {"HELIXKIT_RUNTIME_RUN_ID": "legacy", "SOULSHOUSE_RUNTIME_CHAT_ID": "chat-1"},
        ]:
            with self.subTest(env=env):
                status, request, _ = self.run_cli(quiet, ["chat-1"], stdin="reason", env=env)
                self.assertEqual(status, 64)
                self.assertIsNone(request)

    def test_quiet_destination_is_required_and_mutually_exclusive(self):
        for args in [[], ["chat-1", "--telegram", "thread-1"]]:
            with self.subTest(args=args):
                status, request, _ = self.run_cli(quiet, args)
                self.assertEqual(status, 2)
                self.assertIsNone(request)


if __name__ == "__main__":
    unittest.main()
