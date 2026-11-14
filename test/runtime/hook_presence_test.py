"""A run reports the hooks Chaos would load and which ones fired (jaMBVj).

Only ids, events and status cross to Rails: never a hook's command or output.
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SECRET_COMMAND = "exec python3 /secret/session_start.py --token=abc123"
SECRET_OUTPUT = "Lume wake context: soul.md text that must never leave the box"


def listing(*rows):
    return json.dumps(list(rows))


def row(hook_id, event, enabled=True, approved=True, inactive_reason=None, project="/home/agent/identity", matcher=None):
    return {
        "id": hook_id,
        "revision": 1,
        "definition": {"event": event, "command": SECRET_COMMAND, "project": project,
                       "matcher": matcher, "timeout_sec": 90, "order": 0,
                       "status_message": "Waking"},
        "enabled": enabled,
        "approved": approved,
        "inactive_reason": inactive_reason,
    }


class HookPresenceTest(unittest.TestCase):
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
            "hook_presence_shim",
            Path(__file__).resolve().parents[2] / "agent-runtime" / "trigger_shim.py",
        )
        self.shim = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.shim)
        patch.object(self.shim, "jsonify", side_effect=lambda body: body).start()
        self.root = root

    def fake_list(self, stdout, returncode=0):
        calls = []

        def run(args, **kwargs):
            calls.append((args, kwargs))
            return subprocess.CompletedProcess(args, returncode, stdout, "")
        return run, calls

    def test_inventory_keeps_ids_and_status_only(self):
        run, calls = self.fake_list(listing(
            row("house-project-v1-1", "session_start"),
            row("house-project-v1-2", "before_turn", approved=False),
            row("house-project-v1-3", "stop", inactive_reason="project is not trusted", matcher="^resume$"),
        ))
        inventory = self.shim.hook_inventory(self.root, {"CHAOS_HOME": "/x"}, run=run)

        self.assertEqual(calls[0][0][1:], ["hooks", "list"])
        self.assertEqual(calls[0][1]["cwd"], str(self.root))
        self.assertEqual(calls[0][1]["env"], {"CHAOS_HOME": "/x"})
        self.assertEqual(inventory, {"status": "ok", "hooks": [
            {"id": "house-project-v1-1", "event": "session_start", "enabled": True, "approved": True,
             "inactive_reason": None, "project_scoped": True, "has_matcher": False},
            {"id": "house-project-v1-2", "event": "before_turn", "enabled": True, "approved": False,
             "inactive_reason": None, "project_scoped": True, "has_matcher": False},
            {"id": "house-project-v1-3", "event": "stop", "enabled": True, "approved": True,
             "inactive_reason": "project is not trusted", "project_scoped": True, "has_matcher": True},
        ]})
        self.assertNotIn("secret", json.dumps(inventory))
        self.assertNotIn("^resume$", json.dumps(inventory))

    def test_an_empty_store_is_an_empty_list_not_unknown(self):
        run, _calls = self.fake_list("[]\n")
        self.assertEqual(self.shim.hook_inventory(self.root, {}, run=run), {"status": "ok", "hooks": []})

    def test_a_failure_to_look_is_reported_not_raised(self):
        run, _calls = self.fake_list("", returncode=2)
        self.assertEqual(self.shim.hook_inventory(self.root, {}, run=run),
                         {"status": "unavailable", "reason": "chaos hooks list exited 2"})
        run, _calls = self.fake_list("warning: not json")
        self.assertEqual(self.shim.hook_inventory(self.root, {}, run=run)["status"], "unavailable")

        def slow(args, **kwargs):
            raise subprocess.TimeoutExpired(args, 10)
        self.assertEqual(self.shim.hook_inventory(self.root, {}, run=slow),
                         {"status": "unavailable", "reason": "chaos hooks list timed out"})

        def missing(args, **kwargs):
            raise FileNotFoundError(2, "No such file or directory")
        self.assertIn("failed to start", self.shim.hook_inventory(self.root, {}, run=missing)["reason"])

    def test_hook_events_are_parsed_without_their_entries(self):
        events = self.shim.parse_events("\n".join(json.dumps(event) for event in [
            {"type": "process.started", "process_id": "p1"},
            {"type": "hook.started", "turn_id": "t1", "id": "chaos://hooks/house-project-v1-1",
             "event_name": "session_start", "status": "running", "started_at": 1},
            {"type": "hook.completed", "turn_id": "t1", "id": "chaos://hooks/house-project-v1-1",
             "event_name": "session_start", "status": "completed", "started_at": 1,
             "completed_at": 2, "duration_ms": 812, "entries": [{"kind": "context", "text": SECRET_OUTPUT}]},
            {"type": "hook.completed", "turn_id": "t1", "id": "chaos://hooks/house-project-v1-2",
             "event_name": "before_turn", "status": "failed", "duration_ms": 25000},
            {"type": "hook.completed", "id": "chaos://hooks/x", "event_name": "bogus", "status": "completed"},
        ]))
        self.assertEqual(events["hook_runs"], [
            {"id": "house-project-v1-1", "event": "session_start", "status": "completed", "duration_ms": 812},
            {"id": "house-project-v1-2", "event": "before_turn", "status": "failed", "duration_ms": 25000},
        ])
        self.assertNotIn(SECRET_OUTPUT, json.dumps(events))

    def test_without_hook_events_runs_are_unreported_not_empty(self):
        events = self.shim.parse_events(json.dumps({"type": "process.started", "process_id": "p1"}))
        self.assertIsNone(events["hook_runs"])
        self.shim._activity_context.hook_inventory = {"status": "ok", "hooks": []}
        self.assertEqual(self.shim.hook_report(events),
                         {"status": "ok", "hooks": [], "runs_reported": False, "runs": []})

    def test_the_report_rides_in_the_telemetry_envelope(self):
        self.shim._activity_context.hook_inventory = {"status": "ok", "hooks": [
            {"id": "house-project-v1-1", "event": "session_start", "enabled": True, "approved": True,
             "inactive_reason": None, "project_scoped": True}]}
        stdout = "\n".join(json.dumps(event) for event in [
            {"type": "process.started", "process_id": "p1"},
            {"type": "hook.completed", "id": "chaos://hooks/house-project-v1-1",
             "event_name": "session_start", "status": "completed"},
        ])
        result = subprocess.CompletedProcess(["synthetic-chaos"], 0, stdout, "")
        with self.assertLogs(self.shim.log, level="INFO"):
            response, status = self.shim.instrumented_response(
                session_id="synthetic-session", result=result, events=self.shim.parse_events(stdout),
                invocation_text="synthetic prompt", usage={},
                runtime={"provider": "anthropic", "model": "m"}, session={"outcome": "fresh"},
                prompt={"mode": "full"}, resumed=False, fresh_fallback=False, roll=None,
            )
        self.assertEqual(status, 200)
        hooks = response["telemetry"]["hooks"]
        self.assertTrue(hooks["runs_reported"])
        self.assertEqual(hooks["runs"], [{"id": "house-project-v1-1", "event": "session_start", "status": "completed"}])
        self.assertEqual(hooks["hooks"][0]["id"], "house-project-v1-1")

    def test_the_probe_runs_beside_the_turn_and_never_holds_it(self):
        release = __import__("threading").Event()

        def slow(args, **kwargs):
            self.assertIs(kwargs["stdin"], subprocess.DEVNULL)
            release.wait(5)
            return subprocess.CompletedProcess(args, 0, "[]", "")

        import time
        before = time.monotonic()
        probe = self.shim.HookInventoryProbe(self.root, {}, run=slow)
        self.assertLess(time.monotonic() - before, 0.5)
        self.assertEqual(probe.result(timeout=0.05),
                         {"status": "unavailable", "reason": "chaos hooks list was still running"})
        release.set()
        self.assertEqual(probe.result(timeout=5), {"status": "ok", "hooks": []})

    def test_a_probe_that_raises_is_reported(self):
        def broken(args, **kwargs):
            raise ValueError("synthetic")
        probe = self.shim.HookInventoryProbe(self.root, {}, run=broken)
        self.assertEqual(probe.result(timeout=5)["status"], "unavailable")

    def test_listing_is_on_only_where_the_image_turns_it_on(self):
        self.assertFalse(self.shim.hook_inventory_enabled({}))
        self.assertFalse(self.shim.hook_inventory_enabled({"SOULSHOUSE_HOOK_INVENTORY": "0"}))
        self.assertTrue(self.shim.hook_inventory_enabled({"SOULSHOUSE_HOOK_INVENTORY": "1"}))
        dockerfile = (Path(__file__).resolve().parents[2] / "agent-runtime" / "Dockerfile").read_text()
        self.assertIn("ENV SOULSHOUSE_HOOK_INVENTORY=1", dockerfile)

    def test_no_inventory_means_no_hooks_block(self):
        self.shim._activity_context.hook_inventory = None
        telemetry = self.shim.build_telemetry(runtime={}, session={}, prompt={}, usage=None,
                                              hooks=self.shim.hook_report({"hook_runs": None}))
        self.assertNotIn("hooks", telemetry)


if __name__ == "__main__":
    unittest.main()
