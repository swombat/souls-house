"""The cancellable non-reporter path must deliver every prompt byte.

Telegram turns, memory aggregation and any wake without an activity reporter
go through the Popen loop in trigger_shim._run_chaos_once. Before this test,
that loop passed the prompt only to the first communicate() call; CPython
registers stdin for writing only when `input` is truthy, so only what fit in
the pipe during the first half second ever reached Chaos, and a prompt over
~64 KiB hung until the turn deadline (Alanis, 6-9 and 20 Nov 2026).

Run: python3 -m unittest discover -s test/runtime -p 'cancellable_stdin_test.py'
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch


FAKE_CHAOS = """\
import hashlib, json, os, sys, time
mode = os.environ["FAKE_CHAOS_MODE"]
if mode == "late_reader":
    # Chaos starts slowly: nothing reads stdin during the shim's first poll.
    time.sleep(1.2)
    data = sys.stdin.buffer.read()
    print(json.dumps({"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}))
elif mode == "never_reads":
    sys.stdout.write("stdout-marker-before-cancel\\n"); sys.stdout.flush()
    sys.stderr.write("stderr-marker-before-cancel\\n"); sys.stderr.flush()
    time.sleep(60)
"""


def prompt_of(size):
    # Multi-byte UTF-8 on purpose: the shim runs Popen in text mode.
    unit = "Ünïcode prompt line · 2026 ✓\n"
    text = unit * (size // len(unit.encode("utf-8")) + 1)
    return text


class CancellableStdinTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        fake_chaos = root / "fake-chaos"
        fake_chaos.write_text(f"#!{sys.executable}\n" + FAKE_CHAOS)
        fake_chaos.chmod(0o755)
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {
            "HOME": str(root),
            "PATH": os.defpath,
            "PYTHONDONTWRITEBYTECODE": "1",
            "TRIGGER_BEARER_TOKEN": "synthetic-trigger-token",
            "CHAOS_BIN": str(fake_chaos),
            "CHAOS_HOME": str(root / "chaos"),
            "AGENT_IDENTITY_PATH": str(root / "identity"),
            "AGENT_REPO_PATH": str(root),
        }, clear=True).start()
        spec = importlib.util.spec_from_file_location(
            "cancellable_stdin_shim",
            Path(__file__).resolve().parents[2] / "agent-runtime" / "trigger_shim.py",
        )
        self.shim = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.shim)
        self.cancel = threading.Event()
        patch.object(self.shim._activity_context, "cancel_event", self.cancel, create=True).start()
        patch.object(self.shim._activity_context, "reporter", None, create=True).start()

    def run_child(self, mode, prompt, timeout):
        with patch.dict(os.environ, {"FAKE_CHAOS_MODE": mode}):
            return self.shim.run_chaos("synthetic-model", timeout, prompt, False, provider="openai")

    def test_late_reader_receives_every_byte_of_a_200_kib_prompt(self):
        prompt = prompt_of(200 * 1024)
        encoded = prompt.encode("utf-8")
        self.assertGreater(len(encoded), 200 * 1024)
        started = time.monotonic()
        result = self.run_child("late_reader", prompt, 20)
        self.assertLess(time.monotonic() - started, 10, "the prompt write stalled")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "bytes": len(encoded),
            "sha256": hashlib.sha256(encoded).hexdigest(),
        })

    def test_cancel_while_child_never_reads_returns_bounded_with_both_markers(self):
        prompt = prompt_of(200 * 1024)
        threading.Timer(1.0, self.cancel.set).start()
        started = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired) as raised:
            self.run_child("never_reads", prompt, 30)
        self.assertLess(time.monotonic() - started, 10, "cancel was not honoured promptly")
        self.assertIn("stdout-marker-before-cancel", raised.exception.output or "")
        self.assertIn("stderr-marker-before-cancel", raised.exception.stderr or "")


if __name__ == "__main__":
    unittest.main()
