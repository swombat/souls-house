import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "host-runner"))

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402

import souls_house_runner as runner  # noqa: E402

IMAGE = "sha256:" + "a" * 64
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

    def __init__(self, existing=(), address="172.18.0.2", fail=(), images=()):
        self.calls = []
        self.images = set(images)
        self.existing = set(existing)
        self.address = address
        self.fail = set(fail)

    def __call__(self, argv, timeout=120):
        self.calls.append(argv)
        verb = " ".join(argv[1:3])
        if argv[1] in self.fail or verb in self.fail:
            return False, "boom"
        if verb == "network inspect":
            return "network" in self.existing, ""
        if verb == "image inspect":
            return argv[-1] in self.images, argv[-1] if argv[-1] in self.images else ""
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
            spec(image="registry.example/agent@" + IMAGE),
            spec(image="sha256:" + "A" * 64),
            spec(registry_auth={"registry": "r", "username": "u", "password": "p"}),
            spec(image="--volume=/:/host"),
            spec(image=IMAGE + " --privileged"),
            spec(memory_mb=10), spec(memory_mb="1024"), spec(memory_mb=True),
            spec(cpu_shares=1), spec(cpu_shares=99999),
            spec(pids_limit=10), spec(pids_limit=10**6), spec(pids_limit="4096"), spec(pids_limit=True),
            spec(env={"TRIGGER_BEARER_TOKEN": "t", "PATH": "/evil"}),
            spec(env={"TRIGGER_BEARER_TOKEN": "t", "LD_PRELOAD": "/x.so"}),
            spec(env={"TRIGGER_BEARER_TOKEN": "t", "DOCKER_HOST": "tcp://x"}),
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
        self.assertEqual(argv[argv.index("--pids-limit") + 1], str(runner.DEFAULT_PIDS_LIMIT))
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

    def test_the_pids_limit_comes_from_the_spec(self):
        argv = runner.create_argv(runner.validate_resident_spec(spec(pids_limit=2048)), "/state/residents/x.env")
        self.assertEqual(argv[argv.index("--pids-limit") + 1], "2048")


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
        self.loaded = []

        def load_image(image_id):
            self.loaded.append(image_id)
            self.docker.images.add(image_id)
            return True, ""

        self.host = runner.ResidentHost(self.dir, docker=self.docker, http=self.http, sleep=lambda s: None,
                                        load_image=load_image)

    def test_start_creates_network_volumes_pulls_by_digest_creates_and_waits_for_health(self):
        result = self.host.start_resident(spec())
        self.assertEqual(result["state"], "running")
        verbs = self.docker.verbs()
        self.assertEqual(verbs[:2], ["network inspect", "network create"])
        self.assertEqual(verbs.count("volume create"), 5)
        self.assertEqual(self.loaded, [IMAGE])
        self.assertFalse(any(argv[1] == "pull" for argv in self.docker.calls))
        self.assertIn("create", verbs)
        self.assertEqual(verbs[-2:], ["start", "inspect"])
        self.assertEqual(self.http.calls[-1]["url"], "http://172.18.0.2:4000/health")
        env_path = os.path.join(self.dir, "residents", "agent-pilot-1.env")
        self.assertEqual(os.stat(env_path).st_mode & 0o777, 0o600)
        with open(env_path) as handle:
            self.assertIn("TRIGGER_BEARER_TOKEN=trig\n", handle.read())

    def test_an_image_already_present_is_not_fetched_again(self):
        self.docker.images.add(IMAGE)
        self.host.start_resident(spec())
        self.assertEqual(self.loaded, [])

    def test_a_fetch_that_loads_something_else_never_runs(self):
        self.host.load_image = lambda image_id: (True, "")  # loaded, but not this ID
        with self.assertRaises(runner.CommandFailed):
            self.host.start_resident(spec())
        self.assertNotIn("create", self.docker.verbs())

    def test_a_failed_fetch_stops_before_create(self):
        self.host.load_image = lambda image_id: (False, "house answered 404")
        with self.assertRaises(runner.CommandFailed):
            self.host.start_resident(spec())
        self.assertNotIn("create", self.docker.verbs())

    def test_starting_again_unchanged_keeps_the_container(self):
        self.host.start_resident(spec())
        self.docker.calls.clear()
        self.host.start_resident(spec())
        self.assertNotIn("create", self.docker.verbs())
        self.assertNotIn("rm", self.docker.verbs())

    def test_a_changed_image_recreates_the_container_but_keeps_volumes(self):
        self.host.start_resident(spec())
        self.docker.calls.clear()
        self.host.start_resident(spec(image="sha256:" + "b" * 64))
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

    def test_a_changed_pids_limit_recreates_the_container(self):
        self.host.start_resident(spec(pids_limit=4096))
        self.docker.calls.clear()
        self.host.start_resident(spec(pids_limit=8192))
        self.assertIn(["docker", "rm", "-f", "agent-pilot-1"], self.docker.calls)
        self.assertIn("create", self.docker.verbs())

    def test_a_container_recorded_before_pids_limit_is_not_recreated_for_it(self):
        self.host.start_resident(spec())
        record = os.path.join(self.dir, "residents", "agent-pilot-1.json")
        with open(record) as handle:
            legacy = json.load(handle)
        del legacy["pids_limit"]
        with open(record, "w") as handle:
            json.dump(legacy, handle)
        self.docker.calls.clear()
        self.host.start_resident(spec())
        self.assertNotIn("create", self.docker.verbs())
        self.assertNotIn("rm", self.docker.verbs())
        with open(record) as handle:
            self.assertNotIn("pids_limit", json.load(handle))  # still created without one
        self.host.start_resident(spec(image="sha256:" + "b" * 64))
        with open(record) as handle:
            self.assertEqual(json.load(handle)["pids_limit"], runner.DEFAULT_PIDS_LIMIT)

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


class FetchImageTest(unittest.TestCase):
    CONFIG = {"rails_url": "https://house.example", "runner_id": "rnr_abc"}

    def test_a_signed_get_streams_the_image_and_only_200_counts(self):
        seen, written = [], []

        class Response:
            def __init__(self, status, chunks):
                self.status = status
                self.chunks = list(chunks)

            def read(self, size):
                return self.chunks.pop(0) if self.chunks else b""

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def opener(request, timeout=None):
            seen.append(request)
            return Response(200, [b"tar-", b"bytes"])

        key = Ed25519PrivateKey.generate()
        ok, _ = runner.fetch_image(self.CONFIG, key, IMAGE, written.append, opener=opener)
        self.assertTrue(ok)
        self.assertEqual(b"".join(written), b"tar-bytes")
        self.assertEqual(seen[0].get_method(), "GET")
        self.assertEqual(seen[0].full_url, "https://house.example/api/v1/host_runner/images/" + IMAGE)
        self.assertIn("X-runner-signature", seen[0].headers)
        ok, error = runner.fetch_image(self.CONFIG, key, IMAGE, written.append,
                                       opener=lambda request, timeout=None: Response(204, []))
        self.assertFalse(ok)
        for bad in ("../x", "sha256:abc", None):
            self.assertFalse(runner.fetch_image(self.CONFIG, key, bad, written.append, opener=opener)[0])


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
            for server in (resident, elsewhere):
                server.shutdown()
                server.server_close()
        self.assertEqual(response["status"], 302)
        self.assertEqual(hits["elsewhere"], 0)


class ImageFetchRedirectTest(unittest.TestCase):
    def test_an_image_fetch_never_follows_a_redirect_to_another_host(self):
        import http.server
        import threading

        hits = {"elsewhere": 0}

        class Elsewhere(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                hits["elsewhere"] += 1
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"foreign-archive")

            def log_message(self, *args):
                pass

        elsewhere = http.server.HTTPServer(("127.0.0.1", 0), Elsewhere)

        class House(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{elsewhere.server_port}/image.tar")
                self.end_headers()

            def log_message(self, *args):
                pass

        house = http.server.HTTPServer(("127.0.0.1", 0), House)
        for server in (elsewhere, house):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        written = []
        config = {"rails_url": f"http://127.0.0.1:{house.server_port}", "runner_id": "rnr_" + "0" * 20}
        try:
            ok, error = runner.fetch_image(config, Ed25519PrivateKey.generate(), IMAGE, written.append)
        finally:
            for server in (house, elsewhere):
                server.shutdown()
                server.server_close()
        self.assertFalse(ok)
        self.assertIn("302", error)
        self.assertEqual(written, [])
        self.assertEqual(hits["elsewhere"], 0)


class DockerLoadTest(unittest.TestCase):
    """docker_load_from_house itself, with a Python child standing in for
    docker load."""

    def child(self, script):
        def popen(argv, **kwargs):
            self.assertEqual(argv, ["docker", "load"])
            self.process = runner.subprocess.Popen([sys.executable, "-c", script], **kwargs)
            return self.process
        return popen

    def test_a_failed_fetch_returns_at_once_and_reaps_the_child(self):
        import time
        load = runner.docker_load_from_house({}, None, popen=self.child("import time; time.sleep(30)"),
                                             fetch=lambda *args, **kwargs: (False, "house answered 404"), deadline=60)
        started = time.monotonic()
        ok, error = load(IMAGE)
        self.assertLess(time.monotonic() - started, 10)
        self.assertEqual((ok, error), (False, "house answered 404"))
        self.assertIsNotNone(self.process.poll())

    def test_a_chatty_child_cannot_deadlock_the_writer(self):
        import time
        script = ("import sys; sys.stderr.write('x' * (2 * 1024 * 1024)); sys.stderr.flush(); "
                  "data = sys.stdin.buffer.read(); sys.exit(0 if len(data) == 1024 * 1024 else 3)")

        def fetch(config, key, image_id, write, deadline=None):
            for _ in range(16):
                write(b"y" * (64 * 1024))
            return True, ""

        load = runner.docker_load_from_house({}, None, popen=self.child(script), fetch=fetch, deadline=60)
        started = time.monotonic()
        self.assertEqual(load(IMAGE), (True, ""))
        self.assertLess(time.monotonic() - started, 30)

    def test_a_child_that_stops_reading_is_killed_at_the_deadline(self):
        import time

        def fetch(config, key, image_id, write, deadline=None):
            try:
                for _ in range(64):
                    write(b"y" * (1024 * 1024))
            except OSError as error:
                return False, str(error)
            return True, ""

        load = runner.docker_load_from_house({}, None, popen=self.child("import time; time.sleep(60)"),
                                             fetch=fetch, deadline=1)
        started = time.monotonic()
        ok, error = load(IMAGE)
        self.assertLess(time.monotonic() - started, 15)
        self.assertFalse(ok)
        self.assertIn("did not finish", error)
        self.assertIsNotNone(self.process.poll())

    def test_a_failing_load_reports_the_tail_of_stderr(self):
        script = "import sys; sys.stdin.buffer.read(); sys.stderr.write('no space left on device'); sys.exit(1)"
        load = runner.docker_load_from_house({}, None, popen=self.child(script),
                                             fetch=lambda c, k, i, write, deadline=None: (write(b"z") or True, ""), deadline=60)
        self.assertEqual(load(IMAGE), (False, "no space left on device"))

    def test_a_fetch_stalled_before_its_next_write_is_bounded_by_the_deadline(self):
        import time

        def fetch(config, key, image_id, write, deadline=None):
            time.sleep(5)  # a response that stops sending, before any write
            return True, ""

        load = runner.docker_load_from_house({}, None, popen=self.child("import time; time.sleep(60)"),
                                             fetch=fetch, deadline=0.5)
        started = time.monotonic()
        ok, error = load(IMAGE)
        self.assertLess(time.monotonic() - started, 3)
        self.assertFalse(ok)
        self.assertIn("did not finish", error)
        self.assertIsNotNone(self.process.poll())

    def test_a_fetch_that_raises_still_kills_and_reaps_the_child(self):
        import time

        def fetch(config, key, image_id, write, deadline=None):
            raise RuntimeError("malformed response")

        load = runner.docker_load_from_house({}, None, popen=self.child("import time; time.sleep(60)"),
                                             fetch=fetch, deadline=60)
        started = time.monotonic()
        ok, error = load(IMAGE)
        self.assertLess(time.monotonic() - started, 5)
        self.assertFalse(ok)
        self.assertIn("malformed response", error)
        self.assertIsNotNone(self.process.poll())


class FetchImageFailureTest(unittest.TestCase):
    CONFIG = {"rails_url": "https://house.example", "runner_id": "rnr_" + "0" * 20}

    class Response:
        status = 200

        def __init__(self, read):
            self.read1 = read

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def test_an_incomplete_chunked_read_is_a_failure_not_an_exception(self):
        import http.client

        def broken(size):
            raise http.client.IncompleteRead(b"partial")

        written = []
        ok, error = runner.fetch_image(self.CONFIG, Ed25519PrivateKey.generate(), IMAGE, written.append,
                                       opener=lambda request, timeout=None: self.Response(broken))
        self.assertFalse(ok)
        self.assertIn("IncompleteRead", error)

    def test_a_fetch_past_its_deadline_stops_at_the_next_read(self):
        import time
        reads = []

        def read(size):
            reads.append(size)
            return b"x"

        written = []
        ok, error = runner.fetch_image(self.CONFIG, Ed25519PrivateKey.generate(), IMAGE, written.append,
                                       opener=lambda request, timeout=None: self.Response(read),
                                       deadline=time.monotonic() - 1)
        self.assertFalse(ok)
        self.assertIn("deadline", error)
        self.assertEqual((reads, written), ([], []))


if __name__ == "__main__":
    unittest.main()
