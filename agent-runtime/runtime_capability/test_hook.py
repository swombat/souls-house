"""Exercise real trigger routing with synthetic process responses, not Chaos."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
with patch.dict("os.environ", {"TRIGGER_BEARER_TOKEN": "test"}):
    import trigger_shim as shim
from runtime_capability import boundary


class HookTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        patcher = patch.object(
            boundary, "RECEIPT_PATH", Path(directory.name) / "latest.json")
        patcher.start()
        self.addCleanup(patcher.stop)

    def exercise(self, persistent, record, fail_resume=False, delta="delta",
                 actual_check=False):
        prompts = []

        def run(model, timeout, prompt, **kwargs):
            prompts.append((prompt, kwargs.get("resume_id")))
            failed = fail_resume and kwargs.get("resume_id")
            events = "" if failed else "\n".join([
                json.dumps({"type": "process.started", "process_id": "synthetic"}),
                json.dumps({"type": "item.completed", "item": {
                    "type": "agent_message", "text": "synthetic reply"}}),
            ])
            return subprocess.CompletedProcess([], 1 if failed else 0, events, "")

        with tempfile.TemporaryDirectory() as directory:
            payload = {"session_id": "synthetic-capability", "request": "full",
                       "request_delta": delta, "persistent_session": persistent,
                       "auth_mode": "api_key", "provider": "openai",
                       "model": "synthetic", "identity_path": "/untrusted"}
            with (
                patch.object(shim, "request", types.SimpleNamespace(
                    headers={"Authorization": "Bearer test"},
                    get_json=lambda silent=True: payload)),
                patch.object(shim, "TRIGGER_BEARER_TOKEN", "test"),
                patch.object(shim, "jsonify", side_effect=lambda data: data),
                patch.object(shim, "AGENT_IDENTITY_PATH", Path(directory)),
                patch.object(shim, "AGENT_RUNTIME_DOCS_PATH", Path(directory)),
                patch.object(shim, "graph_memory_notice", return_value=None),
                patch.object(shim, "capability_notice",
                             side_effect=boundary.capability_notice if actual_check else None,
                             return_value="CHECK-NOTICE") as check,
                patch.object(boundary.log, "info") as receipt,
                patch.object(shim, "load_session_record", return_value=record),
                patch.object(shim, "roll_decision", return_value=(None, [])),
                patch.object(shim, "save_session_record"),
                patch.object(shim, "retire_session_record"),
                patch.object(shim, "update_session_record"),
                patch.object(shim, "run_chaos", side_effect=run),
            ):
                result, status = shim.trigger()
                check.assert_called_once_with(Path(directory))
                if actual_check:
                    receipt.assert_called_once_with(
                        "capability_discovery outcome=%s", "absent")
                self.assertEqual(status, 200)
                self.assertEqual(result["status"], "ok")
            self.assertTrue(prompts)
            for prompt, _ in prompts:
                self.assertEqual(prompt.count("CHECK-NOTICE"), 0 if actual_check else 1)
            self.assertNotIn("synthetic-capability", shim._running_sessions)
            return prompts

    def test_legacy_fresh(self):
        prompts = self.exercise(False, None)
        self.assertEqual(len(prompts), 1)
        self.assertIn("full", prompts[0][0])

    def test_persistent_fresh(self):
        self.assertEqual(len(self.exercise(True, None)), 1)

    def test_successful_resume(self):
        prompts = self.exercise(True, {"chaos_process_id": "synthetic"})
        self.assertEqual(len(prompts), 1)
        self.assertIn("delta", prompts[0][0])
        self.assertEqual(prompts[0][1], "synthetic")

    def test_resume_without_delta(self):
        prompts = self.exercise(True, {"chaos_process_id": "synthetic"}, delta=None)
        self.assertIn("full", prompts[0][0])

    def test_failed_resume_reuses_check(self):
        prompts = self.exercise(True, {"chaos_process_id": "synthetic"}, True)
        self.assertEqual(len(prompts), 2)
        self.assertEqual(prompts[0][1], "synthetic")
        self.assertIsNone(prompts[1][1])
        self.assertIn("full", prompts[1][0])

    def test_real_absent_worker_receipt_across_routing(self):
        for persistent, record, fail_resume in [
            (False, None, False),
            (True, None, False),
            (True, {"chaos_process_id": "synthetic"}, False),
            (True, {"chaos_process_id": "synthetic"}, True),
        ]:
            with self.subTest(persistent=persistent, record=record,
                              fail_resume=fail_resume):
                self.exercise(persistent, record, fail_resume, actual_check=True)


if __name__ == "__main__":
    unittest.main()
