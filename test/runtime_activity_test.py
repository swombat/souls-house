"""Synthetic reporter tests: local HTTP only, no model/provider calls."""
import datetime
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import threading
import time
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("runtime_activity", Path(__file__).parents[1] / "agent-runtime/runtime_activity.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReporterTest(unittest.TestCase):
    def setUp(self):
        self.packets = []
        self.status = 200
        self.share = True
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                owner.packets.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                self.send_response(owner.status)
                self.end_headers()
                self.wfile.write(json.dumps({"share_narration": owner.share}).encode())

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        run = str(uuid.uuid4())
        self.config = {
            "run_id": run, "path": f"/api/v1/runtime_runs/{run}/events", "token": "synthetic-token",
            "deadline": (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=2)).isoformat(),
            "share_narration": True,
        }
        self.origin = f"http://127.0.0.1:{self.server.server_port}"
        self.reporter = module.Reporter(self.config, self.origin, "openai", "api_key")

    def tearDown(self):
        self.reporter.disabled = True
        self.reporter.wake.set()
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join()

    def events(self):
        return [event for packet in self.packets for event in packet["events"]]

    def test_terminal_telemetry_scrubs_paths_before_transport(self):
        self.reporter.finish(({"status": "ok", "telemetry": {
            "session": {"changed_files": ["CANARY"], "chaos_process_id": "session-1"},
            "runtime": {"stderr": "CANARY", "model": "test-model"},
            "raw": "CANARY",
        }}, 200))
        self.assertNotIn("CANARY", json.dumps(self.packets))
        self.assertIn("session-1", json.dumps(self.packets))

    def test_legacy_echo_is_suppressed_without_deduplicating_repeated_text(self):
        self.reporter.begin_attempt()
        for canonical in (True, False, True):
            self.reporter.project({"type": "item.completed", "item": {
                "type": "agent_message", "phase": "commentary", "canonical": canonical,
                "text": "A legitimately repeated update",
            }})
        self.reporter.finish(({"status": "ok"}, 200))
        self.assertEqual(2, sum(event["type"] == "commentary.completed" for event in self.events()))

    def test_only_public_projection_is_sent(self):
        self.reporter.begin_attempt()
        for kind in ("reasoning", "agent_message", "mcp_tool_call", "command_execution"):
            self.reporter.project({"type": "item.completed", "item": {
                "id": "a", "type": kind, "text": "CANARY", "arguments": {"secret": "CANARY"},
                "command": "CANARY", "aggregated_output": "CANARY", "result": "CANARY",
            }})
        self.reporter.finish(({"status": "ok"}, 200))
        self.assertNotIn("CANARY", json.dumps(self.packets))
        self.assertIn("tool.finished", [event["type"] for event in self.events()])

    def test_explicit_commentary_and_consent_are_both_required(self):
        self.reporter.begin_attempt()
        for phase in (None, "final_answer", "commentary"):
            self.reporter.project({"type": "item.completed", "item": {
                "id": str(phase), "type": "agent_message", "phase": phase, "text": str(phase),
            }})
        self.reporter.share = False
        self.reporter.project({"type": "item.completed", "item": {
            "type": "agent_message", "phase": "commentary", "text": "PRIVATE",
        }})
        self.reporter.finish(({"status": "ok"}, 200))
        text = [event["data"]["text"] for event in self.events() if event["type"] == "commentary.completed"]
        self.assertEqual(["commentary"], text)

    def test_subprocess_events_arrive_before_exit_and_final_jsonl_is_preserved(self):
        script = """
import json,time
print(json.dumps({"type":"process.started","process_id":"session"}),flush=True)
print(json.dumps({"type":"turn.started"}),flush=True)
time.sleep(.5)
print(json.dumps({"type":"turn.completed","usage":{"input_tokens":1}}),flush=True)
"""
        result = self.reporter.run([sys.executable, "-c", script], "synthetic", {}, 3)
        self.assertEqual(0, result.returncode)
        self.assertIn("session", result.stdout)
        self.assertIn("turn.completed", result.stdout)
        self.assertIn("turn.started", [event["type"] for event in self.events()])
        self.reporter.finish(({"status": "ok"}, 200))

    def test_stderr_cannot_block_stdout_drain(self):
        script = "import sys;sys.stderr.write('x'*200000);print('{\"type\":\"turn.started\"}',flush=True)"
        result = self.reporter.run([sys.executable, "-c", script], "", {}, 3)
        self.assertLessEqual(len(result.stderr), 4000)
        self.assertEqual(0, result.returncode)

    def test_timeout_reaps_owned_process(self):
        before = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            self.reporter.run([sys.executable, "-c", "import time;time.sleep(60)"], "", {}, .1)
        self.assertLess(time.monotonic() - before, 5)
        self.reporter.finish(({"status": "timeout"}, 504))
        self.assertEqual("timed_out", self.events()[-1]["data"]["outcome"])

    def test_fallback_has_distinct_attempt_identity(self):
        self.reporter.begin_attempt()
        first = self.reporter.attempt_id
        self.reporter.begin_attempt()
        second = self.reporter.attempt_id
        self.reporter.finish(({"status": "ok"}, 200))
        self.assertNotEqual(first, second)
        self.assertIn("fallback", [event["type"] for event in self.events()])
        self.assertEqual({1, 2}, {packet["attempt_number"] for packet in self.packets})

    def test_unavailable_endpoint_does_not_block_execution(self):
        self.status = 503
        before = time.monotonic()
        result = self.reporter.run([sys.executable, "-c", "print('{\"type\":\"turn.started\"}')"], "", {}, 3)
        self.assertEqual(0, result.returncode)
        self.assertLess(time.monotonic() - before, 2)

    def test_foreign_callback_path_is_rejected(self):
        with self.assertRaises(ValueError):
            module.Reporter({**self.config, "path": "/steal"}, self.origin, "openai", "api_key")


if __name__ == "__main__":
    unittest.main()
