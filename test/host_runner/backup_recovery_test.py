import json
import os
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "host-runner"))
import souls_house_runner as runner


class BackupRecoveryTest(unittest.TestCase):
    def test_restart_contains_tools_before_unpause_and_reports_exact_command(self):
        with tempfile.TemporaryDirectory() as root:
            calls = []
            tools = ["souls-house-backup-" + "a" * 24]
            paused = [True]

            def docker(argv):
                calls.append(argv)
                if argv[1] == "ps":
                    return True, "\n".join(tools + ["unrelated-container"])
                if argv[1] == "rm":
                    tools.clear()
                    return True, ""
                if argv[1] == "unpause":
                    paused[0] = False
                    return True, ""
                return True, json.dumps({"Paused": paused[0], "Running": True, "Status": "running"})

            host = runner.ResidentHost(root, docker=docker)
            host._known_resident = lambda name: None
            host.current_command_id = "b" * 32
            host.begin_backup_recovery("agent-pilot")
            host.recover_backup()
            self.assertFalse(os.path.exists(host._backup_marker()))
            proof = host.backup_recovery_facts()["recovered_backup"]
            self.assertEqual("b" * 32, proof["command_id"])
            self.assertTrue(proof["tools_stopped"])
            self.assertTrue(proof["unpaused"])
            self.assertLess(next(i for i, a in enumerate(calls) if a[1] == "rm"),
                            next(i for i, a in enumerate(calls) if a[1] == "unpause"))
            self.assertNotIn("unrelated-container", next(a for a in calls if a[1] == "rm"))

    def test_failed_containment_never_unpauses_or_reports_recovery(self):
        with tempfile.TemporaryDirectory() as root:
            calls = []

            def docker(argv):
                calls.append(argv)
                if argv[1] == "ps":
                    return True, "souls-house-backup-" + "a" * 24
                return False, "daemon unavailable"

            host = runner.ResidentHost(root, docker=docker)
            host._known_resident = lambda name: None
            host.current_command_id = "b" * 32
            host.begin_backup_recovery("agent-pilot")
            with self.assertRaises(runner.CommandFailed):
                host.recover_backup()
            self.assertTrue(os.path.exists(host._backup_marker()))
            self.assertEqual({}, host.backup_recovery_facts())
            self.assertFalse(any(a[1] == "unpause" for a in calls))

    def test_heartbeat_continues_during_blocking_command(self):
        beat = threading.Event()
        host = type("Host", (), {"backup_recovery_facts": lambda self: {}})()

        def poll(*args):
            self.assertTrue(beat.wait(1))
            return True

        result = runner.poll_with_heartbeats(poll, {}, None, None, host,
                                             lambda *args: beat.set(), lambda _: {},
                                             interval=0.01)
        self.assertTrue(result)
