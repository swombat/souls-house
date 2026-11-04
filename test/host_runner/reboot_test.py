import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "host-runner"))

import souls_house_runner as runner  # noqa: E402

COMMAND_ID = "c" * 32

class KernelFactsTest(unittest.TestCase):
    """What the house needs to decide a reboot: running vs installed kernel and
    whether Debian asks for one (#reboot, 4 Nov: Janis ran 6.12.107 two days
    after 6.12.115 was installed)."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.modules = os.path.join(self.dir, "modules")
        for release in ("6.12.107+deb13-amd64", "6.12.115+deb13-amd64", "6.12.99+deb13-amd64"):
            os.makedirs(os.path.join(self.modules, release, "kernel"))
        # A leftover modules directory with no kernel in it is not a kernel.
        os.makedirs(os.path.join(self.modules, "6.12.200+deb13-amd64"))
        self.required = os.path.join(self.dir, "reboot-required")

    def facts(self, release="6.12.107+deb13-amd64"):
        return runner.reboot_facts(required_path=self.required, modules_dir=self.modules, release=release)

    def test_installed_is_the_newest_kernel_by_version_not_by_text(self):
        self.assertEqual(runner.kernel_installed(self.modules), "6.12.115+deb13-amd64")

    def test_nothing_required_reports_kernels_and_no_reboot(self):
        self.assertEqual(self.facts(), {
            "kernel_running": "6.12.107+deb13-amd64", "kernel_installed": "6.12.115+deb13-amd64",
            "reboot_required": False, "reboot_host": runner.REBOOT_VERSION,
        })

    def test_required_says_since_when(self):
        open(self.required, "w").close()
        os.utime(self.required, (1_800_000_000, 1_800_000_000))
        facts = self.facts()
        self.assertTrue(facts["reboot_required"])
        self.assertEqual(facts["reboot_required_since"], 1_800_000_000)

    def test_no_modules_directory_means_unknown(self):
        self.assertIsNone(runner.kernel_installed(os.path.join(self.dir, "missing")))

    def test_collect_facts_carries_the_kernel_facts(self):
        facts = runner.collect_facts(server_id_reader=lambda: 1, command_runner=lambda argv: None)
        for key in ("kernel_running", "kernel_installed", "reboot_required", "reboot_host"):
            self.assertIn(key, facts)


class ChaosExecTest(unittest.TestCase):
    def proc(self, *argvs):
        root = tempfile.mkdtemp()
        for pid, argv in enumerate(argvs, start=10):
            os.makedirs(os.path.join(root, str(pid)))
            with open(os.path.join(root, str(pid), "cmdline"), "wb") as handle:
                handle.write(b"\0".join(argv) + b"\0")
        os.makedirs(os.path.join(root, "self"))
        return root

    def test_a_chaos_exec_anywhere_on_the_host_is_busy(self):
        self.assertTrue(runner.chaos_exec_running(self.proc([b"/usr/local/bin/chaos", b"exec", b"--json"])))

    def test_other_chaos_processes_and_mentions_are_not(self):
        self.assertFalse(runner.chaos_exec_running(self.proc(
            [b"/usr/local/bin/chaos", b"journald"], [b"bash", b"-c", b"chaos exec"], [b"/usr/bin/python3", b"x.py"])))


class RebootHostTest(unittest.TestCase):
    def host(self, required=True, busy=False):
        state = tempfile.mkdtemp()
        path = os.path.join(state, "reboot-required")
        if required:
            open(path, "w").close()
        return runner.ResidentHost(state, reboot_required_path=path, chaos_running=lambda: busy,
                                   kernel=lambda: {"kernel_running": "old", "kernel_installed": "new"})

    def run_command(self, host, payload=None, state=None):
        state = state or runner.CommandState(tempfile.mkdtemp())
        command = {"id": COMMAND_ID, "kind": "reboot_host", "generation": 1, "payload": payload or {}}
        return runner.execute_command(command, state, host)[1], state

    def test_required_and_idle_answers_but_does_not_arm_by_itself(self):
        host = self.host()
        result, _ = self.run_command(host)
        self.assertEqual(result, {"outcome": "done",
                                  "result": {"state": "rebooting", "kernel_running": "old", "kernel_installed": "new"}})
        self.assertFalse(host.reboot_requested, "only an accepted answer arms the reboot")

    def test_not_required_is_refused_and_does_not_reboot(self):
        host = self.host(required=False)
        result, _ = self.run_command(host)
        self.assertEqual(result, {"outcome": "refused", "error": "no reboot required"})
        self.assertFalse(host.reboot_requested)

    def test_a_running_chaos_exec_is_refused_and_does_not_reboot(self):
        host = self.host(busy=True)
        result, _ = self.run_command(host)
        self.assertEqual(result["outcome"], "refused")
        self.assertIn("busy", result["error"])
        self.assertFalse(host.reboot_requested)

    def test_arguments_are_refused(self):
        host = self.host()
        result, _ = self.run_command(host, payload={"command": "rm -rf /"})
        self.assertEqual(result["outcome"], "refused")
        self.assertFalse(host.reboot_requested)

    def test_a_redelivery_answers_from_memory(self):
        host = self.host()
        _, state = self.run_command(host)
        result, _ = self.run_command(self.host(), state=runner.CommandState(state.path.rsplit("/", 1)[0]))
        self.assertEqual(result["outcome"], "done")


class AcceptedAnswerTest(unittest.TestCase):
    """The VM reboots only once the house has accepted reboot_host's answer
    (Mira, #778 round 1)."""

    def setUp(self):
        self.state_dir = tempfile.mkdtemp()
        self.marker = os.path.join(self.state_dir, "reboot-required")
        open(self.marker, "w").close()
        self.busy = False
        self.host = runner.ResidentHost(self.state_dir, reboot_required_path=self.marker,
                                        chaos_running=lambda: self.busy, kernel=lambda: {})
        self.state = runner.CommandState(self.state_dir)
        self.config = {"rails_url": "https://house.example", "runner_id": "r" * 32}
        self.key = runner.load_or_create_key(self.state_dir)

    def opener(self, result_status=200, result_error=None):
        command = {"id": COMMAND_ID, "kind": "reboot_host", "generation": 1, "payload": {}}

        def opener(request, timeout=None):
            if request.full_url.endswith("/commands/next"):
                return Response(200, {"command": command})
            if result_error is not None:
                raise result_error
            if result_status >= 400:
                raise urllib.error.HTTPError(request.full_url, result_status, "err", {}, io.BytesIO(b"{}"))
            return Response(result_status, {"status": "recorded"})
        return opener

    def poll(self, **kwargs):
        return runner.poll_command_once(self.config, self.key, self.state, self.host, opener=self.opener(**kwargs))

    def test_accepted_answer_arms_the_reboot(self):
        self.assertTrue(self.poll())
        self.assertTrue(self.host.reboot_requested)

    def test_rejected_answer_does_not(self):
        for status in (409, 500):
            self.host.reboot_requested = False
            self.poll(result_status=status)
            self.assertFalse(self.host.reboot_requested, status)

    def test_transport_failure_does_not(self):
        self.poll(result_error=urllib.error.URLError("refused"))
        self.assertFalse(self.host.reboot_requested)

    def test_an_exception_while_answering_does_not(self):
        with self.assertRaises(RuntimeError):
            self.poll(result_error=RuntimeError("boom"))
        self.assertFalse(self.host.reboot_requested)

    def test_a_redelivery_accepted_later_arms_it_once(self):
        self.poll(result_status=500)
        self.assertFalse(self.host.reboot_requested)
        self.poll()
        self.assertTrue(self.host.reboot_requested, "the remembered answer, accepted now, reboots")
        # After the reboot Debian no longer asks: a further redelivery doesn't.
        self.host.reboot_requested = False
        os.remove(self.marker)
        self.poll()
        self.assertFalse(self.host.reboot_requested)

    def test_a_chaos_exec_started_before_acceptance_stops_it(self):
        self.poll(result_status=500)
        self.busy = True
        self.poll()
        self.assertFalse(self.host.reboot_requested)

    def test_other_commands_never_arm_it(self):
        self.host.arm_reboot({"kind": "home_stats"}, {"outcome": "done", "result": {"state": "rebooting"}})
        self.assertFalse(self.host.reboot_requested)


class Response:
    def __init__(self, status, payload):
        self.status = status
        self._body = json.dumps(payload).encode()

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class RebootLoopTest(unittest.TestCase):
    """main() reboots only after the answer is sent, and takes no command
    while the machine shuts down."""

    def run_main(self, reboot_ok):
        state = tempfile.mkdtemp()
        open(os.path.join(state, "enrolled"), "w").close()
        config_path = os.path.join(state, "config.json")
        with open(config_path, "w") as handle:
            json.dump({"rails_url": "https://house.example", "runner_id": "r" * 32, "commands_enabled": True}, handle)
        events = []
        host = runner.ResidentHost(state, reboot_required_path=config_path, chaos_running=lambda: False,
                                   kernel=lambda: {})
        host.recover_backup = lambda: None
        polls = iter([True, False, False])

        def poll(config, key, command_state, resident_host):
            handled = next(polls, False)
            if handled and not events:
                resident_host.arm_reboot({"kind": "reboot_host"},
                                         {"outcome": "done", "result": {"state": "rebooting"}})
                events.append("answered")
            else:
                events.append("polled")
            return handled

        def reboot():
            events.append("reboot")
            return reboot_ok

        code = runner.main(config_path=config_path, state_dir=state, sleep=lambda s: events.append(f"sleep {s}"),
                           heartbeat=lambda *a: None, facts=lambda image: {}, max_heartbeats=2, poll=poll,
                           clock=iter(range(0, 10000, 100)).__next__, host_factory=lambda config, key: host,
                           reboot=reboot)
        return code, events

    def test_answer_then_reboot_then_wait_without_polling(self):
        code, events = self.run_main(reboot_ok=True)
        self.assertEqual(code, 0)
        self.assertEqual(events[:3], ["answered", "reboot", f"sleep {runner.REBOOT_GRACE_SECONDS}"])

    def test_a_failed_reboot_goes_on_polling(self):
        _, events = self.run_main(reboot_ok=False)
        self.assertEqual(events[:3], ["answered", "reboot", "polled"])


if __name__ == "__main__":
    unittest.main()
