import base64
import hashlib
import http.client
import json
import os
import socket
import stat
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "host-runner"))

import backup_proxy as backup
from souls_house_runner import BadCommand, CommandFailed

UUID = "0f8fad5b-d9cb-469f-a165-70867728950e"
DIGEST = "c" * 64
SNAPSHOT = "d" * 64


def payload(**overrides):
    # Include non-ASCII and Ruby-style float spelling. The runner is deliberately
    # not an independent verifier of the envelope payload's Ruby JSON digest.
    raw = ('{"payload":{"version":1,"resident_uuid":"' + UUID +
           '","nodes":[],"edges":[],"settings":{},"note":"héllo","float":1.0e-07},'
           '"sha256":"' + DIGEST + '"}')
    result = {
        "container_name": "agent-pilot-1", "agent_uuid": UUID,
        "agent_slug": "pilot-1", "restic_password": "synthetic-password",
        "checkpoint_json": raw, "checkpoint_digest": DIGEST,
        "checkpoint_file_sha256": hashlib.sha256(raw.encode()).hexdigest(),
        "deadline_seconds": 600,
    }
    result.update(overrides)
    return result


class FakeHost:
    def __init__(self):
        self.known = []

    def _known_resident(self, name):
        self.known.append(name)
        return {"container_name": name}


class FakeProxy:
    instances = []

    def __init__(self, callback, deadline):
        self.callback = callback
        self.deadline = deadline
        self.repository = "rest:http://backup:synthetic@127.0.0.1:12345/"
        self.instances.append(self)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass


class FakeDocker:
    def __init__(self, running=True, paused=False, status=None):
        self.running = running
        self.paused = paused
        self.status = status or ("running" if running else "exited")
        self.calls = []
        self.image_present = True
        self.fail = {}
        self.summary = {"message_type": "summary", "snapshot_id": SNAPSHOT, "total_bytes_processed": 12345}
        self.init_output = ""
        self.checkpoint_bytes = None
        self.env_text = None
        self.temp_paths = []
        self.missing_role = None
        self.paused_for_restic = []
        self.advance = None

    def __call__(self, argv, timeout=120):
        self.calls.append((list(argv), timeout))
        self.assert_positive(timeout)
        verb = " ".join(argv[1:3])
        if verb in self.fail:
            value = self.fail[verb]
            if callable(value):
                return value()
            return value
        if verb == "inspect --format":
            return True, json.dumps({"Running": self.running, "Paused": self.paused, "Status": self.status})
        if verb == "volume inspect":
            return (False, "") if self.missing_role and argv[-1].endswith("-" + self.missing_role) else (True, "")
        if verb == "image inspect":
            return self.image_present, ""
        if verb == "pull restic/restic:0.18.1":
            self.image_present = True
            return True, ""
        if argv[1] == "pause":
            self.paused = True
            return True, ""
        if argv[1] == "unpause":
            self.paused = False
            return True, ""
        if argv[1] == "run":
            self.paused_for_restic.append(self.paused)
            env = argv[argv.index("--env-file") + 1]
            self.temp_paths.append(env)
            assert stat.S_IMODE(os.stat(env).st_mode) == 0o600
            with open(env) as handle:
                self.env_text = handle.read()
            checkpoint_mount = next(value for value in argv if "dst=/data/memory-graph," in value)
            checkpoint_dir = checkpoint_mount.split(",src=")[1].split(",dst=")[0]
            checkpoint = os.path.join(checkpoint_dir, "checkpoint.json")
            assert stat.S_IMODE(os.stat(checkpoint).st_mode) == 0o600
            self.temp_paths.append(checkpoint)
            with open(checkpoint, "rb") as handle:
                self.checkpoint_bytes = handle.read()
            if self.advance is not None:
                self.advance()
            if "init" in argv:
                return (not self.init_output), self.init_output
            if "backup" in argv:
                return True, 'ignored non-JSON line\n{"message_type":"status"}\n' + json.dumps(self.summary)
        if verb == "rm -f":
            return True, ""
        raise AssertionError("unexpected Docker command: " + repr(argv))

    @staticmethod
    def assert_positive(timeout):
        assert timeout > 0


class PayloadTest(unittest.TestCase):
    def test_exact_checkpoint_bytes_not_reserialized(self):
        spec, data = backup.validate_payload(payload())
        self.assertEqual(data, payload()["checkpoint_json"].encode())
        self.assertEqual(spec["checkpoint_digest"], DIGEST)
        self.assertIn(b"1.0e-07", data)

    def test_null_checkpoint(self):
        p = payload(checkpoint_json="null", checkpoint_digest=None,
                    checkpoint_file_sha256=hashlib.sha256(b"null").hexdigest())
        self.assertEqual(backup.validate_payload(p)[1], b"null")

    def test_bad_fields_and_injected_options_are_refused(self):
        for overrides in (
            {"container_name": "../other"}, {"container_name": "--privileged"},
            {"agent_uuid": "a" * 36}, {"agent_slug": "foo,bar"}, {"agent_slug": "bad\nslug"},
            {"restic_password": "pw\nAWS_SECRET_ACCESS_KEY=oops"}, {"restic_password": ""},
            {"checkpoint_digest": "x" * 64}, {"checkpoint_file_sha256": "a" * 64},
            {"deadline_seconds": True}, {"deadline_seconds": 20}, {"deadline_seconds": 3601},
            {"image": "arbitrary"}, {"AWS_ACCESS_KEY_ID": "not allowed"},
        ):
            with self.subTest(overrides=overrides), self.assertRaises(BadCommand):
                backup.validate_payload(payload(**overrides))
        p = payload()
        del p["agent_uuid"]
        with self.assertRaises(BadCommand):
            backup.validate_payload(p)

    def test_checkpoint_scope_version_digest_and_duplicates(self):
        for raw in (
            "{}",
            payload()["checkpoint_json"].replace(UUID, "ffffffff-ffff-ffff-ffff-ffffffffffff"),
            payload()["checkpoint_json"].replace('"version":1', '"version":true'),
            payload()["checkpoint_json"].replace('"version":1', '"version":2'),
            payload()["checkpoint_json"].replace('"nodes":[]', '"nodes":{}'),
            payload()["checkpoint_json"].replace(DIGEST, "a" * 64),
            payload()["checkpoint_json"].replace('"version":1', '"version":1,"version":1'),
            payload()["checkpoint_json"].replace("1.0e-07", "NaN"),
            "null",
            "\ud800",
        ):
            file_sha = hashlib.sha256(raw.encode("utf-8", "surrogatepass")).hexdigest()
            with self.subTest(raw=raw[:60]), self.assertRaises(BadCommand):
                backup.validate_payload(payload(checkpoint_json=raw, checkpoint_file_sha256=file_sha))

    def test_checkpoint_size_bound(self):
        with patch.object(backup, "MAX_CHECKPOINT_BYTES", 16), self.assertRaises(BadCommand):
            backup.validate_payload(payload())


class RunBackupTest(unittest.TestCase):
    def setUp(self):
        self.docker = FakeDocker()
        self.host = FakeHost()
        self.callback = lambda *args, **kwargs: (200, {}, b"")

    def run_backup(self, p=None, **kwargs):
        return backup.run_backup(p or payload(), self.host, signed_request=self.callback,
                                 docker=self.docker, proxy_factory=FakeProxy, **kwargs)

    def test_running_pause_init_backup_cleanup_unpause_and_report(self):
        result = self.run_backup()
        self.assertEqual(result["snapshot_id"], SNAPSHOT)
        self.assertEqual(result["checkpoint_digest"], DIGEST)
        self.assertEqual(result["checkpoint_file_sha256"], payload()["checkpoint_file_sha256"])
        self.assertEqual(result["size_bytes"], 12345)
        self.assertTrue(result["unpaused"])
        self.assertGreaterEqual(result["duration_ms"], 0)
        self.assertEqual(self.host.known, ["agent-pilot-1"])
        self.assertEqual(self.docker.paused_for_restic, [True, True])
        commands = [argv for argv, _ in self.docker.calls]
        pause = next(i for i, argv in enumerate(commands) if argv[1] == "pause")
        init = next(i for i, argv in enumerate(commands) if "init" in argv)
        run = next(i for i, argv in enumerate(commands) if "backup" in argv)
        cleanup = next(i for i, argv in enumerate(commands) if argv[1] == "rm")
        unpause = next(i for i, argv in enumerate(commands) if argv[1] == "unpause")
        self.assertLess(pause, init)
        self.assertLess(init, run)
        self.assertLess(run, cleanup)
        self.assertLess(cleanup, unpause)
        self.assertEqual(self.docker.checkpoint_bytes, payload()["checkpoint_json"].encode())
        self.assertEqual(self.docker.env_text, "RESTIC_PASSWORD=synthetic-password\n")
        self.assertTrue(all(not os.path.exists(path) for path in self.docker.temp_paths))

    def test_fixed_read_only_mounts_host_network_and_tags_no_cloud_secrets(self):
        self.run_backup()
        command = next(argv for argv, _ in self.docker.calls if "backup" in argv)
        self.assertEqual(command[command.index("--network") + 1], "host")
        self.assertIn("--read-only", command)
        self.assertIn(backup.RESTIC_IMAGE, command)
        self.assertIn("--no-cache", command)
        mounts = [command[i + 1] for i, arg in enumerate(command) if arg == "--mount"]
        self.assertEqual(len(mounts), 5)
        self.assertTrue(all(mount.endswith(",readonly") for mount in mounts))
        for role in backup.ROLES:
            self.assertIn(f"type=volume,src=agent-pilot-1-{role},dst=/data/{role},readonly", mounts)
        self.assertFalse(any("dst=/data/state" in mount for mount in mounts))
        self.assertNotIn("souls-house-residents", command)
        self.assertIn("agent_id=" + UUID, command)
        self.assertIn("agent_slug=pilot-1", command)
        self.assertIn("helixkit_volume_set=v1", command)
        self.assertNotIn("synthetic-password", " ".join(command))
        self.assertNotIn("AWS_", " ".join(command))
        self.assertNotIn("forget", command)
        self.assertNotIn("prune", command)

    def test_stopped_and_created_never_pause_or_start(self):
        for status in ("exited", "created"):
            self.docker = FakeDocker(running=False, status=status)
            result = self.run_backup()
            self.assertTrue(result["unpaused"])
            self.assertEqual(self.docker.paused_for_restic, [False, False])
            self.assertFalse(any(argv[1] in ("pause", "unpause", "start") for argv, _ in self.docker.calls))

    def test_already_paused_or_restarting_refused_without_unpause(self):
        for running, paused, status in ((True, True, "running"), (True, False, "restarting"),
                                        (False, False, "dead"), (False, False, "removing")):
            self.docker = FakeDocker(running=running, paused=paused, status=status)
            with self.assertRaises(BadCommand):
                self.run_backup()
            self.assertFalse(any(argv[1] in ("pause", "unpause", "run") for argv, _ in self.docker.calls))

    def test_no_missing_volume_is_created(self):
        self.docker.missing_role = "repo"
        with self.assertRaises(backup.BackupFailed) as caught:
            self.run_backup()
        self.assertTrue(caught.exception.result["unpaused"])
        self.assertFalse(any(argv[1] in ("pause", "run") for argv, _ in self.docker.calls))

    def test_only_fixed_image_download_before_pause(self):
        self.docker.image_present = False
        self.run_backup()
        commands = [argv for argv, _ in self.docker.calls]
        pulls = [argv for argv in commands if argv[1] == "pull"]
        self.assertEqual(pulls, [["docker", "pull", backup.RESTIC_IMAGE]])
        self.assertLess(commands.index(pulls[0]), next(i for i, argv in enumerate(commands) if argv[1] == "pause"))

    def test_restic_init_accepts_only_already_initialized_failure(self):
        self.docker.init_output = "Fatal: repository master key and config already initialized"
        self.assertTrue(self.run_backup()["unpaused"])
        for error in ("permission denied", "repository already exists", "connection timeout"):
            self.docker = FakeDocker()
            self.docker.init_output = error
            with self.subTest(error=error), self.assertRaises(backup.BackupFailed):
                self.run_backup()
            self.assertFalse(self.docker.paused)
            self.assertEqual(len(self.docker.paused_for_restic), 1)

    def test_backup_failure_and_missing_summary_unpause_in_finally(self):
        for summary in ({}, {"message_type": "summary", "snapshot_id": "d" * 8, "total_bytes_processed": 0},
                        {"message_type": "summary", "snapshot_id": SNAPSHOT, "total_bytes_processed": True}):
            self.docker = FakeDocker()
            self.docker.summary = summary
            with self.assertRaises(backup.BackupFailed) as caught:
                self.run_backup()
            self.assertTrue(caught.exception.result["unpaused"])
            self.assertIsNone(caught.exception.result["snapshot_id"])

    def test_pause_failure_or_exception_still_attempts_unpause(self):
        for failure in ((False, "timed out"), lambda: (_ for _ in ()).throw(OSError("lost reply"))):
            self.docker = FakeDocker()
            self.docker.fail["pause agent-pilot-1"] = failure
            with self.assertRaises(backup.BackupFailed):
                self.run_backup()
            self.assertTrue(any(argv[1] == "unpause" for argv, _ in self.docker.calls))

    def test_tempfile_exception_unpauses(self):
        with patch.object(backup.tempfile, "TemporaryDirectory", side_effect=OSError("no space")):
            with self.assertRaises(backup.BackupFailed) as caught:
                self.run_backup()
        self.assertTrue(caught.exception.result["unpaused"])

    def test_unpause_failure_reports_false_and_keeps_snapshot_digest(self):
        self.docker.fail["unpause agent-pilot-1"] = (False, "daemon unavailable")
        with self.assertRaises(backup.BackupFailed) as caught:
            self.run_backup()
        self.assertFalse(caught.exception.result["unpaused"])
        self.assertEqual(caught.exception.result["snapshot_id"], SNAPSHOT)
        self.assertEqual(caught.exception.result["checkpoint_digest"], DIGEST)

    def test_cleanup_failure_does_not_prevent_unpause(self):
        self.docker.fail["rm -f"] = (False, "daemon unavailable")
        with self.assertRaises(backup.BackupFailed) as caught:
            self.run_backup()
        self.assertTrue(caught.exception.result["unpaused"])
        self.assertIn("cleanup", str(caught.exception))

    def test_operation_deadline_is_shared_init_and_backup_not_per_child(self):
        now = [1000.0]
        self.docker.advance = lambda: now.__setitem__(0, now[0] + 40)
        with self.assertRaises(backup.BackupFailed) as caught:
            self.run_backup(payload(deadline_seconds=60), clock=lambda: now[0])
        self.assertTrue(caught.exception.result["unpaused"])
        self.assertEqual(caught.exception.result["duration_ms"], 40000)
        self.assertEqual(len(self.docker.paused_for_restic), 1)
        cleanup = [(argv, timeout) for argv, timeout in self.docker.calls if argv[1] in ("rm", "unpause")]
        self.assertTrue(all(timeout <= 10 for _, timeout in cleanup))

    def test_null_file_is_backed_up_and_reported(self):
        p = payload(checkpoint_json="null", checkpoint_digest=None,
                    checkpoint_file_sha256=hashlib.sha256(b"null").hexdigest())
        result = self.run_backup(p)
        self.assertEqual(self.docker.checkpoint_bytes, b"null")
        self.assertIsNone(result["checkpoint_digest"])


class GrammarTest(unittest.TestCase):
    def test_allowed_rest_wire_paths(self):
        for method, target in (
            ("POST", "/?create=true"),
            *[(method, "/config") for method in ("GET", "HEAD", "POST")],
            *[("GET", f"/{kind}/") for kind in backup.TYPES],
            *[(method, f"/{kind}/{'a' * 64}") for kind in backup.TYPES for method in ("GET", "HEAD", "POST")],
            ("DELETE", "/locks/" + "a" * 64),
        ):
            self.assertEqual(backup.rest_path(method, target), backup.BACKUP_PATH + target)

    def test_bad_queries_methods_paths_and_sharding(self):
        for method, target in (
            ("GET", "/?create=true"), ("POST", "/?create=false"), ("POST", "/?create=true&x=1"),
            ("GET", "/config?x=1"), ("GET", "/config#fragment"), ("DELETE", "/config"),
            ("DELETE", "/snapshots/" + "a" * 64), ("POST", "/keys/"), ("HEAD", "/keys/"),
            ("PUT", "/config"), ("POST", "/"), ("GET", "/../config"),
            ("GET", "/data/aa/" + "a" * 64), ("GET", "/data/" + "A" * 64),
            ("GET", "/%63onfig"), ("GET", "//config"), ("GET", "http://remote/config"),
        ):
            with self.subTest(target=target), self.assertRaises(BadCommand):
                backup.rest_path(method, target)


class ProxyTest(unittest.TestCase):
    def setUp(self):
        self.seen = []

    def callback(self, method, path, body, timeout=30):
        self.seen.append((method, path, body, timeout))
        return 200, {"Content-Type": "application/vnd.x.restic.rest.v2", "Location": "https://elsewhere"}, b"response"

    def request(self, proxy, method, target, data=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", proxy.server.server_port, timeout=2)
        supplied = {"Authorization": proxy.authorization}
        supplied.update(headers or {})
        try:
            connection.request(method, target, body=data, headers=supplied)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def test_loopback_authenticated_binary_and_create_query_forwarded_exactly(self):
        with backup.BackupProxy(self.callback, time.monotonic() + 30) as proxy:
            self.assertEqual(proxy.server.server_address[0], "127.0.0.1")
            self.assertIn("127.0.0.1", proxy.repository)
            status, headers, body = self.request(proxy, "POST", "/?create=true", b"\x00\xff")
            self.assertEqual(status, 200)
            self.assertEqual(body, b"response")
            self.assertNotIn("Location", headers)
            self.assertEqual(self.seen[0][:3], ("POST", backup.BACKUP_PATH + "/?create=true", b"\x00\xff"))
            self.assertTrue(0 < self.seen[0][3] <= 30)

    def test_auth_required_and_resident_credentials_are_not_accepted(self):
        with backup.BackupProxy(self.callback, time.monotonic() + 30) as proxy:
            for auth in ("", "Bearer synthetic-password", "Basic " + base64.b64encode(b"backup:wrong").decode()):
                self.assertEqual(self.request(proxy, "GET", "/config", headers={"Authorization": auth})[0], 401)
        self.assertEqual(self.seen, [])

    def test_grammar_and_framing_are_rejected_before_callback(self):
        with backup.BackupProxy(self.callback, time.monotonic() + 30) as proxy:
            for method, target, headers in (
                ("GET", "/config?create=true", {}),
                ("DELETE", "/data/" + "a" * 64, {}),
                ("POST", "/config", {"Transfer-Encoding": "chunked"}),
                ("GET", "/config", {"Content-Length": "1"}),
                ("POST", "/config", {"Expect": "100-continue"}),
                ("PUT", "/config", {}),
            ):
                self.assertEqual(self.request(proxy, method, target, b"", headers)[0], 400)
        self.assertEqual(self.seen, [])

    def test_request_body_and_request_count_are_bounded(self):
        with backup.BackupProxy(self.callback, time.monotonic() + 30, max_requests=2) as proxy:
            with patch.object(backup, "MAX_BODY_BYTES", 2):
                self.assertEqual(self.request(proxy, "POST", "/config", b"abc")[0], 413)
            self.assertEqual(self.request(proxy, "GET", "/config")[0], 200)
            self.assertEqual(self.request(proxy, "GET", "/config")[0], 429)
        self.assertEqual(len(self.seen), 1)

    def test_redirect_does_not_escape_loopback_or_return_location(self):
        def redirect(*args, **kwargs):
            return 302, {"Location": "https://not-contacted.invalid/"}, b""
        with backup.BackupProxy(redirect, time.monotonic() + 30) as proxy:
            status, headers, _ = self.request(proxy, "GET", "/config")
            self.assertEqual(status, 502)
            self.assertNotIn("Location", headers)

    def test_head_reports_remote_object_length_not_zero_byte_wire_body(self):
        def head(*args, **kwargs):
            return 200, {"Content-Length": "1234"}, b""
        with backup.BackupProxy(head, time.monotonic() + 30) as proxy:
            status, headers, body = self.request(proxy, "HEAD", "/config")
            self.assertEqual(status, 200)
            self.assertEqual(headers["Content-Length"], "1234")
            self.assertEqual(body, b"")

    def test_oversized_response_and_transport_failure_are_bounded_errors(self):
        def large(*args, **kwargs):
            return 200, {}, b"abc"
        with backup.BackupProxy(large, time.monotonic() + 30) as proxy:
            with patch.object(backup, "MAX_BODY_BYTES", 2):
                self.assertEqual(self.request(proxy, "GET", "/config")[0], 502)
        def timeout(*args, **kwargs):
            raise TimeoutError()
        with backup.BackupProxy(timeout, time.monotonic() + 30) as proxy:
            self.assertEqual(self.request(proxy, "GET", "/config")[0], 502)

    def test_expired_command_deadline_refuses_proxy_requests(self):
        with backup.BackupProxy(self.callback, time.monotonic() - 1) as proxy:
            self.assertEqual(self.request(proxy, "GET", "/config")[0], 429)
        self.assertEqual(self.seen, [])

    def test_slow_incomplete_headers_cannot_block_shutdown(self):
        began = time.monotonic()
        with backup.BackupProxy(self.callback, time.monotonic() + 0.2) as proxy:
            client = socket.create_connection(("127.0.0.1", proxy.server.server_port))
            client.sendall(b"GET /config HTTP/1.1\r\nHost: ")
            time.sleep(0.3)
            client.close()
        self.assertLess(time.monotonic() - began, 2)
        self.assertEqual(self.seen, [])

    def test_stalled_callback_does_not_hold_proxy_and_workers_are_capped(self):
        import threading
        release = threading.Event()
        started = []

        def stalled(*args, **kwargs):
            started.append(1)
            release.wait(2)
            return 200, {}, b""

        with backup.BackupProxy(stalled, time.monotonic() + 30) as proxy:
            try:
                for _ in range(2):
                    with self.assertRaises(TimeoutError):
                        proxy.request("GET", backup.BACKUP_PATH + "/config", b"", timeout=0.01)
                self.assertEqual(proxy.request("GET", backup.BACKUP_PATH + "/config", b"", timeout=0.01)[0], 429)
                self.assertEqual(len(started), 2)
            finally:
                release.set()

    def test_duplicate_auth_and_length_refused(self):
        with backup.BackupProxy(self.callback, time.monotonic() + 30) as proxy:
            for extra, expected in ((f"Authorization: {proxy.authorization}\r\n", 401),
                                    ("Content-Length: 0\r\nContent-Length: 0\r\n", 400)):
                client = socket.create_connection(("127.0.0.1", proxy.server.server_port), timeout=2)
                try:
                    client.sendall((f"GET /config HTTP/1.1\r\nHost: localhost\r\n"
                                    f"Authorization: {proxy.authorization}\r\n{extra}\r\n").encode())
                    response = http.client.HTTPResponse(client)
                    response.begin()
                    self.assertEqual(response.status, expected)
                    response.read()
                finally:
                    client.close()
        self.assertEqual(self.seen, [])


class SignedTransportTest(unittest.TestCase):
    def test_fullpath_signed_binary_bounded_and_no_redirect_follow(self):
        seen = {}

        class Sock:
            def settimeout(self, timeout):
                pass

            def shutdown(self, how):
                pass

        class Response:
            status = 302

            def getheader(self, key, default=None):
                return {"Content-Length": "0", "Content-Type": "application/octet-stream"}.get(key, default)

            def read1(self, size):
                return b""

        class Connection:
            sock = Sock()

            def __init__(self, host, port, timeout):
                seen["origin"] = (host, port)

            def connect(self):
                pass

            def request(self, method, path, body, headers):
                seen["request"] = (method, path, body, headers)

            def getresponse(self):
                return Response()

            def close(self):
                seen["closed"] = True

        def signing(key, method, path, body, runner_id):
            seen["sign"] = (method, path, body, runner_id)
            return {"X-Runner-Signature": "synthetic"}

        with patch.object(backup.http.client, "HTTPSConnection", Connection):
            request = backup.make_signed_request({"rails_url": "https://house.invalid", "runner_id": "runner-1"},
                                                 object(), signing)
            fullpath = backup.BACKUP_PATH + "/?create=true"
            status, headers, body = request("POST", fullpath, b"\x00\xff")
        self.assertEqual(status, 302)
        self.assertEqual(seen["sign"], ("POST", fullpath, b"\x00\xff", "runner-1"))
        self.assertEqual(seen["origin"], ("house.invalid", 443))
        self.assertEqual(seen["request"][3]["Content-Type"], "application/octet-stream")
        self.assertTrue(seen["closed"])

    def test_untrusted_origin_and_arbitrary_remote_path_refused(self):
        with self.assertRaises(Exception):
            backup.make_signed_request({"rails_url": "http://bad.invalid", "runner_id": "1"}, None, None)
        request = backup.make_signed_request({"rails_url": "https://house.invalid", "runner_id": "1"}, None, None)
        with self.assertRaises(BadCommand):
            request("POST", "/api/v1/host_runner/commands/next", b"")


class BoundedDockerTest(unittest.TestCase):
    def test_output_tail_bounded(self):
        ok, output = backup.bounded_docker([sys.executable, "-c", "print('x' * 300000)"], timeout=2)
        self.assertTrue(ok)
        self.assertLessEqual(len(output), backup.OUTPUT_BYTES)

    def test_timeout_kills_and_reaps_process(self):
        before = time.monotonic()
        ok, output = backup.bounded_docker([sys.executable, "-c", "import time; time.sleep(10)"], timeout=0.05)
        self.assertFalse(ok)
        self.assertIn("deadline", output)
        self.assertLess(time.monotonic() - before, 2)


if __name__ == "__main__":
    unittest.main()
