"""soulshouse-plan and the reporter's plan reads (#864), against a fake chaos.

No model, provider or network beyond a local HTTP server."""
import datetime
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).parents[1]
HELPER = ROOT / "agent-runtime/soulshouse-plan"
FAKE = ROOT / "test/fixtures/fake_chaos_plan.py"

spec = importlib.util.spec_from_file_location("runtime_activity_plan", ROOT / "agent-runtime/runtime_activity.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FakeChaos:
    def __init__(self):
        self.dir = tempfile.TemporaryDirectory()
        root = Path(self.dir.name)
        self.home = root / "chaos-home"
        self.home.mkdir()
        self.bin = root / "chaos"
        self.bin.write_text(f"#!/bin/sh\nexec {sys.executable} {FAKE} \"$@\"\n")
        self.bin.chmod(0o755)
        self.env = {"PATH": os.environ["PATH"], "HOME": str(root), "CHAOS_HOME": str(self.home),
                    "FAKE_CHAOS_STATE": str(root / "state.json"), "SOULSHOUSE_CHAOS_BIN": str(self.bin)}

    def plan(self, *args, thread="thread-a", run=None):
        env = dict(self.env, CHAOS_THREAD_ID=thread)
        if run:
            env["SOULSHOUSE_RUNTIME_RUN_ID"] = run
        return subprocess.run([sys.executable, str(HELPER), *args], capture_output=True, text=True, env=env, timeout=30)

    def state(self):
        return json.loads(Path(self.env["FAKE_CHAOS_STATE"]).read_text())

    def close(self):
        self.dir.cleanup()


class HelperTest(unittest.TestCase):
    def setUp(self):
        self.chaos = FakeChaos()

    def tearDown(self):
        self.chaos.close()

    def statuses(self):
        (plan,) = [p for p in self.chaos.state()["plans"].values() if p["status"] == "active"] or \
            [sorted(self.chaos.state()["plans"].values(), key=lambda p: p["reference"])[-1]]
        return plan["status"], [task["status"] for task in plan["tasks"]]

    def test_a_job_moves_from_start_to_done(self):
        run = str(uuid.uuid4())
        result = self.chaos.plan("start", "Ship it", "read", "build", "test", run=run)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("0 of 3", result.stdout)
        self.assertEqual(("active", ["in_progress", "pending", "pending"]), self.statuses())
        self.assertEqual(["thread-a"], list(self.chaos.state()["attachments"]))
        self.assertEqual(0, self.chaos.plan("tick", run=run).returncode)
        self.assertEqual(("active", ["completed", "in_progress", "pending"]), self.statuses())
        self.assertEqual(0, self.chaos.plan("block", "3", "waiting on CI", run=run).returncode)
        self.assertEqual(0, self.chaos.plan("tick", "2", run=run).returncode)
        refused = self.chaos.plan("done", run=run)
        self.assertEqual(1, refused.returncode)
        self.assertIn("step 3 still open", refused.stderr)
        self.assertEqual(0, self.chaos.plan("tick", "3", run=run).returncode)
        done = self.chaos.plan("done", run=run)
        self.assertEqual(0, done.returncode, done.stderr)
        self.assertEqual(("completed", ["completed"] * 3), self.statuses())
        self.assertEqual({}, self.chaos.state()["attachments"])
        pointer = json.loads((self.chaos.home / "house-plans/thread-thread-a.json").read_text())
        self.assertEqual(run, pointer["ended_run_id"])
        self.assertEqual(1, self.chaos.plan("tick", run=run).returncode)

    def test_drop_and_add_keep_the_job_honest(self):
        self.chaos.plan("start", "Job", "one", "two")
        self.assertEqual(0, self.chaos.plan("drop", "2", "not needed").returncode)
        self.assertEqual(0, self.chaos.plan("add", "three").returncode)
        self.assertEqual(("active", ["in_progress", "cancelled", "pending"]), self.statuses())
        self.assertEqual(1, self.chaos.plan("drop", "2", "").returncode)

    def test_a_new_plan_cancels_the_open_one_and_sessions_do_not_share(self):
        self.chaos.plan("start", "First", "a")
        self.chaos.plan("start", "Other session", "x", thread="thread-b")
        self.chaos.plan("start", "Second", "b")
        plans = {p["title"]: p["status"] for p in self.chaos.state()["plans"].values()}
        self.assertEqual({"First": "cancelled", "Other session": "active", "Second": "active"}, plans)

    def test_outside_a_session_it_refuses(self):
        env = dict(self.chaos.env)
        result = subprocess.run([sys.executable, str(HELPER), "start", "T", "a"], capture_output=True,
                                text=True, env=env, timeout=30)
        self.assertEqual(1, result.returncode)
        self.assertIn("CHAOS_THREAD_ID", result.stderr)

    def test_bad_step_numbers_are_refused_plainly(self):
        self.chaos.plan("start", "Job", "one")
        for number in ("0", "2", "x"):
            result = self.chaos.plan("tick", number)
            self.assertEqual(1, result.returncode)
            self.assertNotIn("Traceback", result.stderr)


class ReporterPlanTest(unittest.TestCase):
    def setUp(self):
        self.chaos = FakeChaos()
        self.packets = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                owner.packets.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps({"share_narration": True}).encode())

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.chaos.close()

    def reporter(self, run, share=True):
        config = {"run_id": run, "path": f"/api/v1/runtime_runs/{run}/events", "token": "synthetic-token",
                  "deadline": (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=2)).isoformat(),
                  "share_narration": share}
        return module.Reporter(config, f"http://127.0.0.1:{self.server.server_port}", "anthropic", "oauth_account")

    def run_with(self, reporter, script_lines):
        """Run a stand-in chaos whose stream is `script_lines`; the reporter is
        pointed at the fake CLI for its plan reads."""
        script = ";".join(f"print({json.dumps(json.dumps(line))}, flush=True)" for line in script_lines)
        env = dict(self.chaos.env)
        wrapper = self.chaos.bin.parent / "chaos-stream"
        wrapper.write_text(f"#!/bin/sh\nexec {sys.executable} -c '{script}'\n")
        wrapper.chmod(0o755)
        result = reporter.run([str(wrapper)], "", env, 10)
        reporter.finish(({"status": "ok"}, 200))
        return result

    def plans(self):
        return [event["data"] for packet in self.packets for event in packet["events"] if event["type"] == "plan.updated"]

    def test_a_clamped_residents_ticks_reach_the_run_without_stream_events(self):
        run = str(uuid.uuid4())
        self.chaos.plan("start", "Ship it", "read", "build", "test", thread="session-1", run=run)
        self.chaos.plan("tick", thread="session-1", run=run)
        reporter = self.reporter(run)
        self.run_with(reporter, [{"type": "process.started", "process_id": "session-1"}, {"type": "turn.started"},
                                 {"type": "turn.completed", "usage": {}}])
        plans = self.plans()
        self.assertTrue(plans)
        self.assertEqual({"title": "Ship it", "status": "active", "steps": [
            {"text": "read", "status": "completed"}, {"text": "build", "status": "in_progress"},
            {"text": "test", "status": "pending"}]}, plans[-1])
        self.assertEqual(len(plans), len({json.dumps(plan) for plan in plans}), "unchanged plans are not resent")

    def test_a_session_plan_from_an_earlier_run_shows_while_open_and_not_after_it_ended(self):
        earlier = str(uuid.uuid4())
        self.chaos.plan("start", "Long job", "a", "b", thread="session-1", run=earlier)
        stream = [{"type": "process.started", "process_id": "session-1"}, {"type": "turn.started"}]
        self.run_with(self.reporter(str(uuid.uuid4())), stream)
        self.assertEqual("Long job", self.plans()[-1]["title"])
        self.chaos.plan("tick", thread="session-1", run=earlier)
        self.chaos.plan("tick", thread="session-1", run=earlier)
        self.chaos.plan("done", thread="session-1", run=earlier)
        self.packets.clear()
        self.run_with(self.reporter(str(uuid.uuid4())), stream)
        self.assertEqual([], self.plans())

    def test_a_run_without_a_plan_sends_no_plan(self):
        self.run_with(self.reporter(str(uuid.uuid4())), [{"type": "process.started", "process_id": "session-9"},
                                                          {"type": "turn.started"}])
        self.assertEqual([], self.plans())

    def test_nothing_is_sent_when_narration_is_not_shared(self):
        run = str(uuid.uuid4())
        self.chaos.plan("start", "Private", "a", thread="session-1", run=run)
        self.run_with(self.reporter(run, share=False), [{"type": "process.started", "process_id": "session-1"},
                                                         {"type": "turn.started"}])
        self.assertEqual([], self.plans())

    def test_chaos_plan_tool_events_are_projected_to_titles_and_states_only(self):
        reporter = self.reporter(str(uuid.uuid4()))
        self.run_with(reporter, [{"type": "plan.updated", "plan_id": "p", "reference": "000000/0000",
                                  "title": "Native", "status": "active", "revision": 3, "next_offset": None,
                                  "tasks": [{"reference": "T1", "title": "one", "status": "blocked", "depth": 0},
                                            {"reference": "T2", "title": "child", "status": "pending", "depth": 1},
                                            {"reference": "T3", "title": "odd", "status": "weird", "depth": 0}]}])
        self.assertEqual([{"title": "Native", "status": "active", "steps": [{"text": "one", "status": "blocked"}]}],
                         self.plans())
        self.assertNotIn("000000/0000", json.dumps(self.packets))


if __name__ == "__main__":
    unittest.main()
