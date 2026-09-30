"""Synthetic shim HTTP protocol and subprocess cancellation; no provider calls."""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import uuid

try:
    import flask
except ImportError:
    flask = None


@unittest.skipUnless(flask, "Flask required for HTTP integration")
class AsyncTurnHTTPTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.environment = patch.dict(os.environ, {
            "PATH": os.environ["PATH"], "HOME": self.directory.name,
            "TRIGGER_BEARER_TOKEN": "synthetic",
            "CHAOS_HOME": self.directory.name,
            "AGENT_IDENTITY_PATH": self.directory.name,
            "SOULSHOUSE_TURN_STORE": self.directory.name + "/turns",
        }, clear=True)
        self.environment.start()
        runtime = Path(__file__).parents[1] / "agent-runtime"
        spec = importlib.util.spec_from_file_location("async_http_shim", runtime / "trigger_shim.py")
        self.shim = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = self.shim
        spec.loader.exec_module(self.shim)
        self.client = self.shim.app.test_client()
        self.headers = {"Authorization": "Bearer synthetic"}
        self.turn_id = str(uuid.uuid4())
        self.url = "/turns/" + self.turn_id
        self.payload = {"session_id": "synthetic", "request": "synthetic prompt"}
        self.release = threading.Event()
        self.executions = []

        def run(payload, cancel):
            self.executions.append(payload)
            self.release.wait(3)
            return {"status": 200, "body": {"status": "ok"}}

        self.shim.turn_store().execute = run
        self.headers["X-Resident-Ledger-ID"] = self.shim.turn_store().ledger_id

    def tearDown(self):
        self.release.set()
        for _ in range(200):
            if not self.shim.turn_store().cancellations:
                break
            time.sleep(.01)
        self.shim.turn_store().owner.close()
        self.environment.stop()
        self.directory.cleanup()

    def test_auth_is_required_for_all_operations(self):
        for method in ("get", "post", "delete"):
            self.assertEqual(401, getattr(self.client, method)(self.url, json=self.payload).status_code)
        self.assertEqual([], self.executions)

    def test_acceptance_does_not_wait_and_duplicate_post_does_not_execute_again(self):
        before = time.monotonic()
        response = self.client.post(self.url, json=self.payload, headers=self.headers)
        self.assertEqual(202, response.status_code)
        self.assertLess(time.monotonic() - before, 1)
        self.assertEqual(202, self.client.post(self.url, json=self.payload, headers=self.headers).status_code)
        self.assertEqual(1, len(self.executions))
        self.assertEqual(200, self.client.get(self.url, headers=self.headers).status_code)

    def test_ledger_change_between_probe_and_submit_rejects_execution(self):
        headers = {**self.headers, "X-Resident-Ledger-ID": str(uuid.uuid4())}
        self.assertEqual(409, self.client.post(self.url, json=self.payload, headers=headers).status_code)
        self.assertEqual([], self.executions)

    def test_missing_record_includes_ledger_identity(self):
        response = self.client.get(self.url, headers=self.headers)
        self.assertEqual(404, response.status_code)
        self.assertEqual(self.shim.turn_store().ledger_id, response.json["ledger_id"])

    def test_worker_runs_the_existing_trigger_under_its_own_request_context(self):
        self.shim.turn_store().execute = self.shim.execute_async_turn
        with patch.object(self.shim, "legacy_trigger",
                          side_effect=lambda *args, **kwargs: self.shim.jsonify({"status": "ok", "returncode": 0})):
            response = self.client.post(self.url, json=self.payload, headers=self.headers)
            self.assertEqual(202, response.status_code)
            for _ in range(100):
                response = self.client.get(self.url, headers=self.headers)
                if response.json["state"] == "finished":
                    break
                time.sleep(.01)
            self.assertEqual("finished", response.json["state"])
            self.assertEqual("ok", response.json["result"]["body"]["status"])

    def test_cancel_acknowledges_only_after_execution_returns(self):
        self.client.post(self.url, json=self.payload, headers=self.headers)
        response = self.client.delete(self.url, headers=self.headers)
        self.assertIn(response.json["state"], ("accepted", "running"))
        self.release.set()
        for _ in range(100):
            response = self.client.get(self.url, headers=self.headers)
            if response.json["state"] == "cancelled":
                break
            time.sleep(.01)
        self.assertEqual("cancelled", response.json["state"])

    def test_cancel_before_submission_is_a_durable_tombstone(self):
        response = self.client.delete(self.url, json=self.payload, headers=self.headers)
        self.assertEqual("cancelled", response.json["state"])
        response = self.client.post(self.url, json=self.payload, headers=self.headers)
        self.assertEqual("cancelled", response.json["state"])
        self.assertEqual([], self.executions)

    def test_real_subprocess_can_be_cancelled_without_an_activity_reporter(self):
        executable = Path(self.directory.name) / "synthetic-chaos"
        executable.write_text("#!/bin/sh\nsleep 30\n")
        executable.chmod(0o700)
        cancel = threading.Event()
        timer = threading.Timer(.1, cancel.set)
        self.shim._activity_context.cancel_event = cancel
        timer.start()
        before = time.monotonic()
        try:
            with patch.object(self.shim, "CHAOS_BIN", str(executable)):
                with self.assertRaises(self.shim.subprocess.TimeoutExpired):
                    self.shim.run_chaos("synthetic", 30, "hello", True)
            self.assertLess(time.monotonic() - before, 3)
        finally:
            timer.join()
            self.shim._activity_context.cancel_event = None


if __name__ == "__main__":
    unittest.main()
