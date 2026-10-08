import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "host-runner"))

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402

import souls_house_runner as runner  # noqa: E402

DIGEST = "sha256:" + "a" * 64
IMAGE = f"registry.example/souls-house/agent@{DIGEST}"
DISPATCH = "0f8fad5b-d9cb-469f-a165-70867728950e"


def spec(**overrides):
    base = {
        "container_name": "agent-pilot-1",
        "image": IMAGE,
        "memory_mb": 1024,
        "cpu_shares": 512,
        "env": {"TRIGGER_BEARER_TOKEN": "trig", "SOULSHOUSE_BEARER_TOKEN": "out",
                "SOULSHOUSE_APP_URL": "https://house.example"},
    }
    base.update(overrides)
    return base


def command(kind="start_resident", payload=None, generation=1, cid="a" * 32):
    return {"id": cid, "kind": kind, "generation": generation, "payload": payload if payload is not None else spec()}


class FakeDocker:
    """Records argv; answers from a script keyed by the docker subcommand."""

    def __init__(self, existing=(), address="172.18.0.2", fail=()):
        self.calls = []
        self.envs = []
        self.existing = set(existing)
        self.address = address
        self.fail = set(fail)

    def __call__(self, argv, timeout=120, env=None):
        self.calls.append(argv)
        self.envs.append(env)
        if env and "DOCKER_CONFIG" in env:
            with open(os.path.join(env["DOCKER_CONFIG"], "config.json")) as handle:
                self.pull_config = json.load(handle)
            self.pull_config_mode = os.stat(os.path.join(env["DOCKER_CONFIG"], "config.json")).st_mode & 0o777
        verb = " ".join(argv[1:3])
        if argv[1] in self.fail or verb in self.fail:
            return False, "boom"
        if verb == "network inspect":
            return "network" in self.existing, ""
        if verb == "container inspect":
            return argv[3] in self.existing, ""
        if argv[1] == "create":
            self.existing.add(argv[argv.index("--name") + 1])
            return True, "cid"
        if argv[1] == "inspect":
            return True, self.address
        return True, ""

    def verbs(self):
        return [" ".join(argv[1:3]) if argv[1] in ("network", "volume", "container") else argv[1] for argv in self.calls]


class FakeHttp:
    def __init__(self, status=200, body=None):
        self.calls = []
        self.status = status
        self.body = body or {"status": "ok"}

    def __call__(self, method, url, token, body=None, ledger_id=None, timeout=10):
        self.calls.append(dict(method=method, url=url, token=token, body=body, ledger_id=ledger_id))
        return {"status": self.status, "body": self.body}


class ValidationTest(unittest.TestCase):
    def test_commands_outside_the_vocabulary_are_refused(self):
        for kind in ("exec", "shell", "docker_run", "start_container", "", None, "START_RESIDENT"):
            with self.assertRaises(runner.BadCommand, msg=repr(kind)):
                runner.validate_command(command(kind=kind))

    def test_malformed_envelopes_are_refused(self):
        for bad in (command(cid="../x"), command(cid="A" * 32), command(generation=0),
                    command(generation=True), command(generation="1"), "nope", None,
                    {**command(), "payload": []}):
            with self.assertRaises(runner.BadCommand, msg=repr(bad)):
                runner.validate_command(bad)

    def test_values_cannot_smuggle_flags_or_change_the_container(self):
        bad_specs = [
            spec(container_name="--privileged"),
            spec(container_name="Agent"),
            spec(container_name="a b"),
            spec(image="registry.example/agent:latest"),
            spec(image="--volume=/:/host"),
            spec(image=IMAGE + " --privileged"),
            spec(memory_mb=10), spec(memory_mb="1024"), spec(memory_mb=True),
            spec(cpu_shares=1), spec(cpu_shares=99999),
            spec(env={"TRIGGER_BEARER_TOKEN": "t", "PATH": "/evil"}),
            spec(env={"TRIGGER_BEARER_TOKEN": "t", "LD_PRELOAD": "/x.so"}),
            spec(env={"TRIGGER_BEARER_TOKEN": "t", "DOCKER_HOST": "tcp://x"}),
            spec(env={"TRIGGER_BEARER_TOKEN": "t", "ANTHROPIC_API_KEY": "sk"}),
            spec(env={"TRIGGER_BEARER_TOKEN": "t\nPATH=/evil"}),
            spec(env={"TRIGGER_BEARER_TOKEN": "t\0"}),
            spec(env={"SOULSHOUSE_APP_URL": "https://house.example"}),
            spec(env=[]),
        ]
        for bad in bad_specs:
            with self.assertRaises(runner.BadCommand, msg=repr(bad)):
                runner.validate_resident_spec(bad)

    def test_the_create_argv_is_the_fixed_template(self):
        argv = runner.create_argv(runner.validate_resident_spec(spec()), "/state/residents/agent-pilot-1.env")
        self.assertEqual(argv[:2], ["docker", "create"])
        self.assertEqual(argv[-1], IMAGE)
        for absent in ("--privileged", "-p", "--publish", "--network=host", "/var/run/docker.sock", "--pid", "--cap-add"):
            self.assertNotIn(absent, argv)
        self.assertEqual(argv[argv.index("--network") + 1], runner.RESIDENT_NETWORK)
        self.assertEqual(argv[argv.index("--env-file") + 1], "/state/residents/agent-pilot-1.env")
        mounts = [argv[i + 1] for i, value in enumerate(argv) if value == "-v"]
        self.assertEqual(mounts, [
            "agent-pilot-1-identity:/home/agent/identity",
            "agent-pilot-1-chaos:/home/agent/.chaos",
            "agent-pilot-1-repo:/home/agent/repo",
            "agent-pilot-1-work:/home/agent/work",
            "agent-pilot-1-state:/home/agent/state",
        ])
        # Secrets never appear in argv, where ps would show them.
        self.assertFalse(any("trig" in value or "out" == value for value in argv))


class ExecuteTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.state = runner.CommandState(self.dir)

    class CountingHost:
        def __init__(self, outcome="ok"):
            self.calls = 0
            self.outcome = outcome

        def start_resident(self, payload):
            self.calls += 1
            if self.outcome == "fail":
                raise runner.CommandFailed("no disk")
            return {"state": "running"}

    def test_a_redelivered_command_is_answered_without_running_again(self):
        host = self.CountingHost()
        first = runner.execute_command(command(), self.state, host)
        again = runner.execute_command(command(), runner.CommandState(self.dir), host)
        self.assertEqual(host.calls, 1)
        self.assertEqual(first, again)
        self.assertEqual(first[1]["outcome"], "done")

    def test_an_older_generation_is_refused_once_a_newer_one_was_seen(self):
        host = self.CountingHost()
        runner.execute_command(command(generation=3, cid="b" * 32), self.state, host)
        _, result = runner.execute_command(command(generation=2, cid="c" * 32), self.state, host)
        self.assertEqual(result, {"outcome": "refused", "error": "stale generation"})
        self.assertEqual(host.calls, 1)

    def test_failures_are_reported_not_raised(self):
        _, result = runner.execute_command(command(), self.state, self.CountingHost("fail"))
        self.assertEqual(result, {"outcome": "failed", "error": "no disk"})

    def test_an_unknown_kind_never_reaches_the_host(self):
        command_id, result = runner.execute_command(command(kind="exec"), self.state, object())
        self.assertEqual(command_id, "a" * 32)
        self.assertEqual(result["outcome"], "refused")

    def test_a_restart_mid_command_answers_unknown_and_never_reruns(self):
        host = self.CountingHost()
        self.state.begin("a" * 32, 1)  # the runner died after this point
        _, result = runner.execute_command(command(), runner.CommandState(self.dir), host)
        self.assertEqual(result["outcome"], "unknown")
        self.assertEqual(host.calls, 0)
        _, again = runner.execute_command(command(), runner.CommandState(self.dir), host)
        self.assertEqual(again["outcome"], "unknown")
        self.assertEqual(host.calls, 0)

    def test_dying_during_a_command_leaves_it_marked_in_flight(self):
        class Dying:
            calls = 0

            def start_resident(self, payload):
                Dying.calls += 1
                raise SystemExit("killed")  # not caught: the process is gone
        with self.assertRaises(SystemExit):
            runner.execute_command(command(), self.state, Dying())
        _, result = runner.execute_command(command(), runner.CommandState(self.dir), Dying())
        self.assertEqual(result["outcome"], "unknown")
        self.assertEqual(Dying.calls, 1)

    def test_a_restart_after_begin_keeps_the_higher_generation(self):
        self.state.begin("b" * 32, 3)  # generation 3 started, then the runner died
        host = self.CountingHost()
        _, result = runner.execute_command(command(generation=2, cid="c" * 32), runner.CommandState(self.dir), host)
        self.assertEqual(result, {"outcome": "refused", "error": "stale generation"})
        self.assertEqual(host.calls, 0)

    def test_an_unexpected_error_is_unknown_not_failed(self):
        class Exploding:
            def start_resident(self, payload):
                raise OSError("disk vanished")
        _, result = runner.execute_command(command(), self.state, Exploding())
        self.assertEqual(result["outcome"], "unknown")

    def test_the_result_file_is_private(self):
        runner.execute_command(command(), self.state, self.CountingHost())
        self.assertEqual(os.stat(os.path.join(self.dir, "commands.json")).st_mode & 0o777, 0o600)


class ResidentHostTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.docker = FakeDocker()
        self.http = FakeHttp()
        self.host = runner.ResidentHost(self.dir, docker=self.docker, http=self.http, sleep=lambda s: None)

    def test_start_creates_network_volumes_pulls_by_digest_creates_and_waits_for_health(self):
        result = self.host.start_resident(spec())
        self.assertEqual(result["state"], "running")
        verbs = self.docker.verbs()
        self.assertEqual(verbs[:2], ["network inspect", "network create"])
        self.assertEqual(verbs.count("volume create"), 5)
        self.assertIn(["docker", "pull", IMAGE], self.docker.calls)
        self.assertIn("create", verbs)
        self.assertEqual(verbs[-2:], ["start", "inspect"])
        self.assertEqual(self.http.calls[-1]["url"], "http://172.18.0.2:4000/health")
        env_path = os.path.join(self.dir, "residents", "agent-pilot-1.env")
        self.assertEqual(os.stat(env_path).st_mode & 0o777, 0o600)
        with open(env_path) as handle:
            self.assertIn("TRIGGER_BEARER_TOKEN=trig\n", handle.read())

    def test_a_registry_credential_is_scoped_to_one_pull(self):
        auth = {"registry": "registry.example", "username": "pull-only", "password": "pw"}
        self.host.start_resident(spec(registry_auth=auth))
        pull_env = next(env for argv, env in zip(self.docker.calls, self.docker.envs) if argv[1] == "pull")
        self.assertEqual(list(self.docker.pull_config["auths"]), ["registry.example"])
        self.assertEqual(self.docker.pull_config_mode, 0o600)
        self.assertFalse(os.path.exists(pull_env["DOCKER_CONFIG"]))
        others = [env for argv, env in zip(self.docker.calls, self.docker.envs) if argv[1] != "pull"]
        self.assertTrue(all(env is None for env in others))
        self.assertFalse(any("pw" in value for argv in self.docker.calls for value in argv))

    def test_a_registry_credential_for_another_registry_is_refused(self):
        for auth in ({"registry": "evil.example", "username": "u", "password": "p"},
                     {"registry": "registry.example", "username": "u"},
                     {"registry": "registry.example", "username": "u", "password": "p", "extra": 1},
                     {"registry": "registry.example", "username": "u", "password": "p\nx"}):
            with self.assertRaises(runner.BadCommand, msg=repr(auth)):
                runner.validate_resident_spec(spec(registry_auth=auth))

    def test_starting_again_unchanged_keeps_the_container(self):
        self.host.start_resident(spec())
        self.docker.calls.clear()
        self.host.start_resident(spec())
        self.assertNotIn("create", self.docker.verbs())
        self.assertNotIn("rm", self.docker.verbs())

    def test_a_changed_image_recreates_the_container_but_keeps_volumes(self):
        self.host.start_resident(spec())
        self.docker.calls.clear()
        self.host.start_resident(spec(image=IMAGE.replace("a" * 64, "b" * 64)))
        self.assertIn(["docker", "rm", "-f", "agent-pilot-1"], self.docker.calls)
        self.assertIn("create", self.docker.verbs())
        self.assertFalse(any(argv[1:3] == ["volume", "rm"] for argv in self.docker.calls))

    def test_a_rotated_env_value_recreates_the_container(self):
        self.host.start_resident(spec())
        self.docker.calls.clear()
        rotated = spec(env={**spec()["env"], "TRIGGER_BEARER_TOKEN": "trig-rotated"})
        self.host.start_resident(rotated)
        self.assertIn(["docker", "rm", "-f", "agent-pilot-1"], self.docker.calls)
        self.assertIn("create", self.docker.verbs())
        with open(os.path.join(self.dir, "residents", "agent-pilot-1.json")) as handle:
            self.assertNotIn("trig", handle.read())

    def test_a_failed_pull_stops_before_create(self):
        self.docker.fail.add("pull")
        with self.assertRaises(runner.CommandFailed):
            self.host.start_resident(spec())
        self.assertNotIn("create", self.docker.verbs())

    def test_never_healthy_is_a_failure(self):
        self.http.status = 503
        with self.assertRaises(runner.CommandFailed):
            self.host.start_resident(spec())

    def test_turns_are_relayed_to_the_private_bridge_with_the_stored_token(self):
        self.host.start_resident(spec())
        self.host.submit_turn({"container_name": "agent-pilot-1", "dispatch_id": DISPATCH,
                               "ledger_id": "led_1", "body": {"request": "hi"}})
        call = self.http.calls[-1]
        self.assertEqual(call["method"], "POST")
        self.assertEqual(call["url"], f"http://172.18.0.2:4000/turns/{DISPATCH}")
        self.assertEqual(call["token"], "trig")
        self.assertEqual(call["ledger_id"], "led_1")
        self.host.turn_status({"container_name": "agent-pilot-1", "dispatch_id": DISPATCH})
        self.assertEqual(self.http.calls[-1]["method"], "GET")
        self.host.cancel_turn({"container_name": "agent-pilot-1", "dispatch_id": DISPATCH, "ledger_id": "led_1"})
        self.assertEqual(self.http.calls[-1]["method"], "DELETE")

    def test_turns_for_unknown_residents_or_bad_ids_are_refused(self):
        with self.assertRaises(runner.CommandFailed):
            self.host.submit_turn({"container_name": "agent-other", "dispatch_id": DISPATCH})
        self.host.start_resident(spec())
        for bad in ("../../x", "abc", DISPATCH + "/resolve"):
            with self.assertRaises(runner.BadCommand):
                self.host.submit_turn({"container_name": "agent-pilot-1", "dispatch_id": bad})
        with self.assertRaises(runner.BadCommand):
            self.host.submit_turn({"container_name": "--all", "dispatch_id": DISPATCH})

    def test_an_address_that_is_not_an_ip_is_not_dialled(self):
        self.host.start_resident(spec())
        self.docker.address = "evil.example"
        with self.assertRaises(runner.CommandFailed):
            self.host.submit_turn({"container_name": "agent-pilot-1", "dispatch_id": DISPATCH})

    def test_stop_only_touches_known_residents(self):
        with self.assertRaises(runner.CommandFailed):
            self.host.stop_resident({"container_name": "souls-house-web"})
        self.host.start_resident(spec())
        self.assertEqual(self.host.stop_resident({"container_name": "agent-pilot-1"})["state"], "stopped")
        self.assertIn(["docker", "stop", "--time", "30", "agent-pilot-1"], self.docker.calls)


class PollTest(unittest.TestCase):
    CONFIG = {"rails_url": "https://house.example", "runner_id": "rnr_abc", "commands_enabled": True}

    def test_a_command_is_run_and_its_result_is_reported_signed(self):
        sent = []

        class Response:
            def __init__(self, payload):
                self.status = 200
                self._body = json.dumps(payload).encode()

            def read(self):
                return self._body

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def opener(request, timeout=None):
            sent.append(request)
            if request.full_url.endswith("/commands/next"):
                return Response({"command": command(kind="stop_resident", payload={"container_name": "agent-x"})})
            return Response({"status": "recorded"})

        state = runner.CommandState(tempfile.mkdtemp())
        host = runner.ResidentHost(tempfile.mkdtemp(), docker=FakeDocker(), http=FakeHttp())
        handled = runner.poll_command_once(self.CONFIG, Ed25519PrivateKey.generate(), state, host, opener=opener)
        self.assertTrue(handled)
        self.assertEqual(sent[1].full_url, "https://house.example/api/v1/host_runner/commands/" + "a" * 32 + "/result")
        self.assertIn("X-runner-signature", sent[1].headers)
        self.assertEqual(json.loads(sent[1].data)["outcome"], "failed")

    def test_main_polls_only_when_enabled_and_keeps_heartbeating(self):
        state = tempfile.mkdtemp()
        open(os.path.join(state, "enrolled"), "w").close()
        for enabled, expect_polls in ((True, True), (False, False)):
            config_path = os.path.join(state, "config.json")
            with open(config_path, "w") as handle:
                json.dump({"rails_url": "https://house.example", "runner_id": "r", "commands_enabled": enabled}, handle)
            polls, beats = [], []
            now = [0.0]

            def poll(config, key, st, host):
                polls.append(1)
                now[0] += 30
                return False

            def broken_poll(config, key, st, host):
                raise RuntimeError("network")

            code = runner.main(config_path=config_path, state_dir=state, sleep=lambda s: None,
                               enroll=lambda *a: self.fail("enrolled already"),
                               heartbeat=lambda *a: beats.append(1), facts=lambda image: {},
                               max_heartbeats=3, poll=poll, clock=lambda: now[0])
            self.assertEqual(code, 0)
            self.assertEqual(len(beats), 3)
            self.assertEqual(bool(polls), expect_polls)
            if enabled:
                beats.clear()
                now[0] = 0.0
                ticking = iter(range(0, 10000, 70))
                runner.main(config_path=config_path, state_dir=state, sleep=lambda s: None,
                            enroll=lambda *a: None, heartbeat=lambda *a: beats.append(1), facts=lambda image: {},
                            max_heartbeats=2, poll=broken_poll, clock=lambda: next(ticking))
                self.assertEqual(len(beats), 2)


class RelayRedirectTest(unittest.TestCase):
    def test_the_relay_never_follows_a_redirect(self):
        import http.server
        import threading

        hits = {"elsewhere": 0}

        class Elsewhere(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                hits["elsewhere"] += 1
                self.send_response(200)
                self.end_headers()

            def log_message(self, *args):
                pass

        elsewhere = http.server.HTTPServer(("127.0.0.1", 0), Elsewhere)

        class Resident(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{elsewhere.server_port}/steal")
                self.end_headers()

            def log_message(self, *args):
                pass

        resident = http.server.HTTPServer(("127.0.0.1", 0), Resident)
        for server in (elsewhere, resident):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            response = runner._http("GET", f"http://127.0.0.1:{resident.server_port}/turns/x", "secret-token")
        finally:
            resident.shutdown()
            elsewhere.shutdown()
        self.assertEqual(response["status"], 302)
        self.assertEqual(hits["elsewhere"], 0)


if __name__ == "__main__":
    unittest.main()
