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
    def test_fast_cancellation_polling_does_not_increase_heartbeat_traffic(self):
        self.reporter.cancel_event = threading.Event()
        self.reporter.run([sys.executable, "-c", "import time; time.sleep(1.1)"], "", {}, 5)
        self.reporter.finish(({"status": "ok"}, 200))
        self.assertFalse(any(event["type"] == "heartbeat" for event in self.events()))

    def test_cancellation_terminates_the_supervised_process_without_model_output(self):
        cancel = threading.Event()
        self.reporter.cancel_event = cancel
        timer = threading.Timer(.1, cancel.set)
        timer.start()
        before = time.monotonic()
        try:
            with self.assertRaises(subprocess.TimeoutExpired):
                self.reporter.run([sys.executable, "-c", "import time; time.sleep(30)"], "", {}, 30)
            self.assertLess(time.monotonic() - before, 3)
        finally:
            timer.join()

    def setUp(self):
        self.packets = []
        self.status = 200
        self.share = True
        self.reject_type = None
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                owner.packets.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                rejected = any(event["type"] == owner.reject_type for event in owner.packets[-1]["events"])
                self.send_response(422 if rejected else owner.status)
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

    def child(self, status="running", child_id="private-child", **extra):
        # Exact shape of Chaos #88 CollabAgentStatusChangedEvent. Neither the
        # older collab-tool payload nor its result/message fields are sources.
        return {
            "type": "agent.status_changed", "parent_process_id": "private-parent",
            "child_process_id": child_id, "agent_nickname": "Helper",
            "agent_role": "PRIVATE_ROLE", "model": "synthetic-model", "status": status, **extra,
        }

    def test_exact_lifecycle_is_allowlisted_before_transport_and_not_retained(self):
        script = "print(" + repr(json.dumps(self.child(prompt="PRIVATE_PROMPT", result="PRIVATE_RESULT",
                                                      error={"message": "PRIVATE_ERROR"}))) + ",flush=True)"
        result = self.reporter.run([sys.executable, "-c", script], "", {}, 3)
        self.reporter.finish(({"status": "ok"}, 200))
        child = next(event["data"] for event in self.events() if event["type"] == "agent.status_changed")
        self.assertEqual({"parent_process_id", "child_process_id", "agent_nickname", "model", "status"}, set(child))
        self.assertEqual("synthetic-model", child["model"])
        self.assertEqual("", result.stdout)
        for canary in ("PRIVATE_ROLE", "PRIVATE_PROMPT", "PRIVATE_RESULT", "PRIVATE_ERROR"):
            self.assertNotIn(canary, json.dumps(self.packets))

    def test_completion_reactivation_and_source_reattachment_are_explicit(self):
        self.reporter.begin_attempt()
        for status in ("pending_init", "running", "completed", "running"):
            self.reporter.project(self.child(status))
        self.reporter.project({"type": "process.started", "process_id": "private-parent"})
        self.reporter.emit("heartbeat")
        self.reporter.project(self.child("interrupted"))
        self.reporter.project(self.child("errored"))
        self.reporter.project(self.child("shutdown"))
        self.reporter.project(self.child("not_found"))
        self.reporter.finish(({"status": "ok"}, 200))
        statuses = [event["data"]["status"] for event in self.events() if event["type"] == "agent.status_changed"]
        self.assertEqual(["pending_init", "running", "completed", "running",
                          "interrupted", "errored", "shutdown", "not_found"], statuses)
        heartbeat = next(event for event in self.events() if event["type"] == "heartbeat")
        self.assertEqual("unknown", heartbeat["data"]["subagents"][0]["status"])
        self.assertGreaterEqual(sum(event["type"] == "stream.started" for event in self.events()), 2)

    def test_invalid_jsonl_and_oversized_lines_signal_a_source_gap(self):
        script = "print(" + repr(json.dumps(self.child())) + ");print('not json');print('x'*1048577)"
        self.reporter.run([sys.executable, "-c", script], "", {}, 3)
        self.reporter.emit("heartbeat")
        self.reporter.finish(({"status": "ok"}, 200))
        self.assertGreaterEqual(sum(event["type"] == "stream.gap" for event in self.events()), 2)
        heartbeat = next(event for event in self.events() if event["type"] == "heartbeat")
        self.assertEqual("unknown", heartbeat["data"]["subagents"][0]["status"])

    def test_hidden_narration_transmits_neither_helpers_nor_cached_heartbeat_details(self):
        self.reporter.begin_attempt()
        self.reporter.share = False
        self.reporter.project(self.child())
        self.reporter.emit("heartbeat")
        self.reporter.finish(({"status": "ok"}, 200))
        self.assertNotIn("Helper", json.dumps(self.packets))
        self.assertNotIn("private-child", json.dumps(self.packets))
        self.assertNotIn("subagents", json.dumps(self.packets))
        self.assertFalse(any(event["type"] == "agent.status_changed" for event in self.events()))

    def test_optout_scrubs_queued_mixed_batch_and_isolated_retries(self):
        self.share = False
        self.reject_type = "warning"
        with self.reporter.lock:
            self.reporter.begin_attempt()
            self.reporter.emit("warning")
            self.reporter.project(self.child())
            self.reporter.emit("heartbeat")
        self.reporter.finish(({"status": "ok"}, 200))
        accepted = [packet for packet in self.packets if all(event["type"] != "warning" for event in packet["events"])]
        self.assertNotIn("Helper", json.dumps(accepted))
        self.assertNotIn("private-child", json.dumps(accepted))
        self.assertTrue(any(event["type"] == "supervisor.finished" for packet in accepted for event in packet["events"]))
        # Filtering removes private events, but does not renumber accepted
        # control events or change their payloads/dedupe identity.
        original = next(event for packet in self.packets for event in packet["events"] if event["type"] == "attempt.started")
        replay = next(event for packet in accepted for event in packet["events"] if event["type"] == "attempt.started")
        self.assertEqual(original, replay)

    def test_cache_is_bounded_but_overflow_identity_events_reach_rails_for_distinct_count(self):
        self.reporter.begin_attempt()
        for index in range(40):
            self.reporter.project(self.child(child_id=f"child-{index}", agent_nickname="界" * 300, model="界" * 300))
        self.reporter.emit("heartbeat")
        self.reporter.finish(({"status": "ok"}, 200))
        children = [event["data"] for event in self.events() if event["type"] == "agent.status_changed"]
        self.assertEqual(40, len(children))
        self.assertEqual(32, len(self.reporter.subagents))
        for child in children:
            self.assertLessEqual(len(child["agent_nickname"].encode()), 200)
        for packet in self.packets:
            self.assertLessEqual(len(json.dumps(packet, ensure_ascii=False).encode()), 64 * 1024)

    def test_malformed_events_and_collaboration_tool_results_never_establish_helpers(self):
        self.reporter.begin_attempt()
        for event in (self.child(status={"completed": "PRIVATE"}), self.child(status="unknown"),
                      self.child(child_id=""), self.child(child_id="x" * 201),
                      self.child(parent_process_id=None)):
            self.reporter.project(event)
        self.reporter.project({"type": "item.completed", "item": {
            "id": "spawn", "type": "collab_tool_call", "tool": "spawn_agent",
            "receiver_process_ids": ["private-child"], "status": "completed",
            "agents_states": {"private-child": {"status": "completed", "message": "PRIVATE"}},
            "prompt": "PRIVATE",
        }})
        self.reporter.finish(({"status": "ok"}, 200))
        self.assertFalse(any(event["type"] == "agent.status_changed" for event in self.events()))
        self.assertNotIn("PRIVATE", json.dumps(self.packets))

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
                "command": "curl --token CANARY", "aggregated_output": "CANARY", "result": "CANARY",
            }})
        self.reporter.finish(({"status": "ok"}, 200))
        self.assertNotIn("CANARY", json.dumps(self.packets))
        self.assertIn("tool.finished", [event["type"] for event in self.events()])

    def test_command_previews_preserve_useful_arguments(self):
        cases = {
            "git status --short": "git status --short",
            "/bin/bash -lc 'git diff --stat'": "git diff --stat",
            "bundle exec rails test test/models/agent_test.rb": "bundle exec rails test test/models/agent_test.rb",
            "ls -la /home/agent": "ls -la /home/agent",
            "cat app/models/agent.rb": "cat app/models/agent.rb",
            "cat /home/agent/workspace/souls-house/app/services/agent_dispatch.rb": "cat /home/agent/workspace/souls-house/app/services/agent_dispatch.rb",
            'grep -n "runtime" app/services/agent_dispatch.rb': "grep -n runtime app/services/agent_dispatch.rb",
            "rg 'two words' app": 'rg "two words" app',
            "cd /home/agent && ls -la": "cd /home/agent && ls -la",
            "cat README.md\nls -la": "cat README.md ; ls -la",
            "/usr/bin/git status": "/usr/bin/git status",
            "house-memory status": "house-memory status",
        }
        for command, expected in cases.items():
            with self.subTest(command=command):
                self.assertEqual(expected, module.command_preview(command))
        for invalid in (None, {}, ["CANARY"], "git status " + "CANARY" * 4000):
            self.assertEqual("Command [payload hidden]", module.command_preview(invalid))
        self.assertLessEqual(len(module.command_preview("git status " + "--short " * 300).encode()), 1024)

    def test_credentials_and_opaque_payloads_are_redacted(self):
        commands = [
            "curl -sS -H 'Authorization: Bearer CANARY' https://user:CANARY@example.test/?token=CANARY",
            "git -c http.extraHeader='Authorization: CANARY' status",
            "TOKEN=CANARY git status", "env TOKEN=CANARY git status",
            "python3 -c 'print(\"CANARY\")'", "ruby -eCANARY",
            "node --eval=CANARY",
            "echo $(cat /private/CANARY)", "curl --data @CANARY",
            "curl <<EOF\nCANARY\nEOF", "git status 'unterminated CANARY",
            "git status --short\u001bCANARY", "git status --short\u202eCANARY",
            "curl --token=CANARY", "curl -uuser:CANARY",
            "curl --json '{\"password\":\"CANARY\"}'",
            "echo Bearer CANARY", "sed -e 'CANARY' file", "awk 'CANARY' file",
            "bin/rails runner 'CANARY'", "echo password=CANARY",
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertNotIn("CANARY", module.command_preview(command))
        self.assertEqual("echo [REDACTED]", module._preview_module.preview("echo arbitrary-known-value", ["arbitrary-known-value"]))
        self.assertEqual("echo [REDACTED]", module.command_preview("echo sk-abcdefghijklmnopqrstuv"))

    def test_command_preview_is_safe_in_events_and_heartbeat_before_transport(self):
        self.reporter.begin_attempt()
        self.reporter.project({"type": "item.started", "item": {
            "id": "safe-id", "type": "command_execution",
            "command": "curl -H 'Authorization: Bearer CANARY'", "aggregated_output": "CANARY",
        }})
        self.reporter.emit("heartbeat")
        self.reporter.project({"type": "item.completed", "item": {
            "id": "safe-id", "type": "command_execution",
            "command": "curl -H 'Authorization: Bearer CANARY'", "status": "completed",
        }})
        self.reporter.finish(({"status": "ok"}, 200))
        self.assertNotIn("CANARY", json.dumps(self.packets))
        details = [event["data"] for event in self.events() if event["type"] in ("tool.started", "tool.finished")]
        self.assertEqual(["curl -H [REDACTED]"] * 2, [data["command_preview"] for data in details])
        heartbeat = next(event for event in self.events() if event["type"] == "heartbeat")
        self.assertEqual("curl -H [REDACTED]", heartbeat["data"]["operations"][0]["command_preview"])

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

    def test_rejected_detail_is_isolated_without_losing_control_events(self):
        self.reject_type = "warning"
        with self.reporter.lock:
            self.reporter.begin_attempt()
            self.reporter.emit("warning")
            self.reporter.emit("turn.started")
        self.reporter.finish(({"status": "ok"}, 200))
        accepted = [packet for packet in self.packets if all(
            event["type"] != "warning" for event in packet["events"])]
        types = [event["type"] for packet in accepted for event in packet["events"]]
        self.assertIn("attempt.started", types)
        self.assertIn("supervisor.finished", types)
        self.assertEqual(1, self.reporter.dropped)

    def test_rejected_registration_stops_instead_of_sending_invalid_followups(self):
        self.reject_type = "attempt.started"
        with self.reporter.lock:
            self.reporter.begin_attempt()
            self.reporter.emit("turn.started")
        self.reporter.finish(({"status": "ok"}, 200))
        self.assertTrue(self.reporter.disabled)
        self.assertFalse(any(
            packet["events"][0]["type"] == "turn.started" for packet in self.packets))

    def test_revocation_clears_narration_from_isolated_retry_batches(self):
        self.reject_type = "warning"
        self.share = False
        with self.reporter.lock:
            self.reporter.begin_attempt()
            self.reporter.emit("warning")
            self.reporter.emit("commentary.completed", {"text": "Previously consented"})
        self.reporter.finish(({"status": "ok"}, 200))
        accepted = [packet for packet in self.packets if all(
            event["type"] != "warning" for event in packet["events"])]
        self.assertFalse(any(event["type"] == "commentary.completed"
                             for packet in accepted for event in packet["events"]))

    def test_rejected_heartbeat_does_not_generate_an_endless_repair_loop(self):
        self.reject_type = "heartbeat"
        with self.reporter.lock:
            self.reporter.begin_attempt()
            self.reporter.emit("heartbeat")
        self.reporter.finish(({"status": "ok"}, 200))
        self.assertEqual(1, self.reporter.dropped)
        self.assertLess(len(self.packets), 8)


if __name__ == "__main__":
    unittest.main()
