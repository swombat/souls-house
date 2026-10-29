import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "host-runner"))

import souls_house_runner as runner  # noqa: E402
from commands_test import IMAGE, FakeDocker, FakeHttp, spec  # noqa: E402


class ParityTest(unittest.TestCase):
    """A VM resident gets what a local one gets (#246 parity): its account's
    provider keys, its external-service manifest, and provider logins."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.docker = FakeDocker(images=(IMAGE,))
        self.http = FakeHttp(body={"connected": False})
        self.host = runner.ResidentHost(self.dir, docker=self.docker, http=self.http, sleep=lambda s: None)

    def test_provider_api_keys_are_accepted_and_nothing_else_new_is(self):
        accepted = runner.validate_resident_spec(spec(env={"TRIGGER_BEARER_TOKEN": "t", "ANTHROPIC_API_KEY": "sk",
                                                            "OPENROUTER_API_KEY": "or"}))
        self.assertEqual("sk", accepted["env"]["ANTHROPIC_API_KEY"])
        for bad in ("AWS_SECRET_ACCESS_KEY", "PATH", "HETZNER_API_TOKEN", "DOCKER_HOST"):
            with self.assertRaises(runner.BadCommand, msg=bad):
                runner.validate_resident_spec(spec(env={"TRIGGER_BEARER_TOKEN": "t", bad: "x"}))

    def test_the_service_manifest_is_copied_in_before_start_and_kept_out_of_the_public_spec(self):
        self.host.start_resident(spec(service_manifest="version: 1\nservices: []\n"))
        path = os.path.join(self.dir, "residents", "agent-pilot-1.services.yml")
        self.assertEqual(0o600, os.stat(path).st_mode & 0o777)
        cp = ["docker", "cp", path, "agent-pilot-1:/run/helixkit-source.yml"]
        self.assertIn(cp, self.docker.calls)
        self.assertLess(self.docker.calls.index(cp), next(i for i, argv in enumerate(self.docker.calls) if argv[1] == "start"))
        with open(os.path.join(self.dir, "residents", "agent-pilot-1.json")) as handle:
            public = handle.read()
        self.assertIn("manifest_digest", public)
        self.assertNotIn("services", public)

    def test_a_changed_manifest_recreates_the_container_and_an_unchanged_one_does_not(self):
        self.host.start_resident(spec(service_manifest="version: 1\n"))
        self.docker.calls.clear()
        self.host.start_resident(spec(service_manifest="version: 1\n"))
        self.assertNotIn("create", self.docker.verbs())
        self.host.start_resident(spec(service_manifest="version: 2\n"))
        self.assertIn(["docker", "rm", "-f", "agent-pilot-1"], self.docker.calls)
        self.assertIn("create", self.docker.verbs())

    def test_a_failed_copy_removes_the_new_container_so_a_retry_starts_clean(self):
        self.docker.fail.add("cp")
        with self.assertRaises(runner.CommandFailed):
            self.host.start_resident(spec(service_manifest="version: 1\n"))
        self.assertIn(["docker", "rm", "-f", "agent-pilot-1"], self.docker.calls)
        self.assertNotIn("start", self.docker.verbs())
        self.assertFalse(os.path.exists(os.path.join(self.dir, "residents", "agent-pilot-1.json")))

    def test_oversized_or_malformed_manifests_are_refused(self):
        for bad in (b"x".decode() * (runner.SERVICE_MANIFEST_MAX_BYTES + 1), "a\0b", 12, ["x"]):
            with self.assertRaises(runner.BadCommand):
                runner.validate_resident_spec(spec(service_manifest=bad))

    def test_provider_auth_relays_only_the_fixed_calls_with_the_stored_token(self):
        self.host.start_resident(spec())
        result = self.host.provider_auth({"container_name": "agent-pilot-1", "method": "GET", "path": "/auth/status",
                                          "params": {"provider": "anthropic"}})
        self.assertEqual({"status": 200, "body": {"connected": False}}, result)
        call = self.http.calls[-1]
        self.assertEqual(("GET", "http://172.18.0.2:4000/auth/status?provider=anthropic", "trig"),
                         (call["method"], call["url"], call["token"]))
        self.host.provider_auth({"container_name": "agent-pilot-1", "method": "POST", "path": "/auth/code",
                                 "params": {"provider": "anthropic", "code": "abc#def"}})
        self.assertEqual(("POST", {"provider": "anthropic", "code": "abc#def"}),
                         (self.http.calls[-1]["method"], self.http.calls[-1]["body"]))

    def test_provider_auth_refuses_anything_outside_the_list(self):
        self.host.start_resident(spec())
        bad = [
            {"method": "POST", "path": "/turns/x"}, {"method": "GET", "path": "/auth/start"},
            {"method": "DELETE", "path": "/auth/status"}, {"method": "GET", "path": "/auth/status/../trigger"},
            {"method": "GET", "path": "/auth/status", "params": {"url": "http://evil"}},
            {"method": "GET", "path": "/auth/status", "params": {"provider": ["a"]}},
            {"method": "GET", "path": "/auth/status", "params": {"provider": True}},
            {"method": "GET", "path": "/auth/status", "params": "provider=x"},
        ]
        for payload in bad:
            with self.subTest(payload=payload), self.assertRaises(runner.BadCommand):
                self.host.provider_auth({"container_name": "agent-pilot-1", **payload})
        with self.assertRaises(runner.CommandFailed):
            self.host.provider_auth({"container_name": "agent-other", "method": "GET", "path": "/auth/capabilities"})

    def test_provider_auth_is_in_the_vocabulary(self):
        self.assertIn("provider_auth", runner.COMMAND_KINDS)

    def test_tailnet_runs_only_status_or_up_inside_the_resident_as_agent(self):
        self.host.start_resident(spec())
        self.docker.calls.clear()
        result = self.host.tailnet({"container_name": "agent-pilot-1", "action": "up"})
        self.assertEqual({"ok": True, "output": ""}, result)
        self.assertEqual([["docker", "exec", "-u", "agent", "-e", "HOME=/home/agent", "agent-pilot-1",
                           "timeout", "45", "soulshouse-tailnet", "up", "--json"]], self.docker.calls)

    def test_tailnet_refuses_other_actions_and_unknown_residents(self):
        self.host.start_resident(spec())
        for action in ("down", "logout", "status --json; id", None, ["status"], "ssh"):
            with self.subTest(action=action), self.assertRaises(runner.BadCommand):
                self.host.tailnet({"container_name": "agent-pilot-1", "action": action})
        with self.assertRaises(runner.CommandFailed):
            self.host.tailnet({"container_name": "agent-other", "action": "status"})

    def test_tailnet_reports_a_failed_exec_with_its_output(self):
        self.host.start_resident(spec())
        self.docker.fail.add("exec")
        self.assertEqual({"ok": False, "output": "boom"},
                         self.host.tailnet({"container_name": "agent-pilot-1", "action": "status"}))

    def test_tailnet_is_in_the_vocabulary(self):
        self.assertIn("tailnet", runner.COMMAND_KINDS)

    def test_home_stats_runs_the_fixed_script_inside_the_resident_and_returns_only_numbers(self):
        self.host.start_resident(spec())
        self.docker.calls.clear()
        answers = iter([(True, 'noise\n{"count": 37, "storage_bytes": 2048}')])
        self.host.docker = lambda argv, timeout=120: (self.docker.calls.append(argv), next(answers))[1]
        self.assertEqual({"count": 37, "storage_bytes": 2048}, self.host.home_stats({"container_name": "agent-pilot-1"}))
        self.assertEqual([["docker", "exec", "agent-pilot-1", "timeout", "30", "python3", "-c", runner.HOME_STATS_SCRIPT]],
                         self.docker.calls)

    def test_home_stats_keeps_the_count_when_the_disk_figure_is_missing_or_bad(self):
        self.host.start_resident(spec())
        for size in (None, -1, "12", True):
            with self.subTest(size=size):
                self.host.docker = lambda argv, timeout=120, size=size: (
                    True, runner.json.dumps({"count": 3, "storage_bytes": size}))
                self.assertEqual({"count": 3, "storage_bytes": None},
                                 self.host.home_stats({"container_name": "agent-pilot-1"}))

    def test_home_stats_fails_on_unknown_residents_failed_execs_and_unreadable_answers(self):
        self.host.start_resident(spec())
        with self.assertRaises(runner.CommandFailed):
            self.host.home_stats({"container_name": "agent-other"})
        with self.assertRaises(runner.BadCommand):
            self.host.home_stats({"container_name": "../x"})
        for answer in ((False, "boom"), (True, ""), (True, "private prose"), (True, '{"count": -1}'),
                       (True, '{"count": "3"}'), (True, '{"count": true}'), (True, "[1]")):
            with self.subTest(answer=answer):
                self.host.docker = lambda argv, timeout=120, answer=answer: answer
                with self.assertRaises(runner.CommandFailed):
                    self.host.home_stats({"container_name": "agent-pilot-1"})

    def test_home_stats_is_in_the_vocabulary_and_announced(self):
        self.assertIn("home_stats", runner.COMMAND_KINDS)
        self.assertEqual(1, runner.HOME_STATS_VERSION)

    def test_the_home_stats_script_counts_entries_in_a_real_home(self):
        home = tempfile.mkdtemp()
        journals = os.path.join(home, "daily-journals")
        os.makedirs(journals)
        with open(os.path.join(journals, "2026-10-29.md"), "w") as handle:
            handle.write("# Day\n\n## 09:00 one\nprose\n```\n## fenced\n```\n## 10:00 two\n")
        script = runner.HOME_STATS_SCRIPT.replace("/home/agent/identity/memory/daily-journals", journals)
        out = runner.subprocess.run([sys.executable, "-c", script], capture_output=True, text=True, check=True).stdout
        self.assertEqual(2, runner.json.loads(out)["count"])


if __name__ == "__main__":
    unittest.main()
