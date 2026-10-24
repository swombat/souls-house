import base64
import hashlib
import http.client
import io
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
        if argv[1] == "pull":
            assert argv[-1] == backup.RESTIC_IMAGE
            self.image_present = True
            return True, ""
        if argv[1] == "ps":
            assert argv == ["docker", "ps", "-a", "--filter", backup.BACKUP_TOOL_FILTER,
                            "--format", "{{.Names}}"]
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
        self.assertEqual(self.docker.env_text, "RESTIC_PASSWORD=synthetic-password\n"
                         f"RESTIC_REPOSITORY={FakeProxy.instances[-1].repository}\n")
        self.assertTrue(result["tools_stopped"])
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

    def test_restic_init_accepts_pinned_existing_config_diagnostic_only(self):
        repository = FakeProxy(self.callback, time.monotonic() + 600).repository
        diagnostic = (
            f"Fatal: create repository at {repository} failed: "
            f"Fatal: unable to open repository at {repository}: config file already exists"
        )
        self.docker.init_output = diagnostic
        result = self.run_backup()
        self.assertEqual(result["snapshot_id"], SNAPSHOT)
        self.assertTrue(result["unpaused"])
        self.assertNotIn(repository, json.dumps(result))
        for error in (
            "config file already exists",
            "Fatal: repository already exists",
            diagnostic + ": permission denied",
            "connection timeout\n" + diagnostic,
            diagnostic.replace(" failed: Fatal:", " failed:\nFatal:"),
            diagnostic.replace("unable to open repository", "unable to create repository"),
            diagnostic.replace(f"open repository at {repository}", "open repository at rest:http://other/"),
        ):
            self.docker = FakeDocker()
            self.docker.init_output = error
            with self.subTest(error=error), self.assertRaises(backup.BackupFailed) as caught:
                self.run_backup()
            self.assertEqual(str(caught.exception), "restic init failed")
            self.assertNotIn(repository, json.dumps(caught.exception.result))
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

    def test_cleanup_failure_prevents_unsafe_unpause(self):
        self.docker.fail["rm -f"] = (False, "daemon unavailable")
        with self.assertRaises(backup.BackupFailed) as caught:
            self.run_backup()
        self.assertFalse(caught.exception.result["unpaused"])
        self.assertFalse(caught.exception.result["tools_stopped"])
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
                ("POST", "/config", {"Transfer-Encoding": "gzip, chunked"}),
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


class ChunkedBodyTest(unittest.TestCase):
    def request(self, proxy, wire_body, extra="", target="/config"):
        client = socket.create_connection(("127.0.0.1", proxy.server.server_port), timeout=2)
        try:
            client.sendall((f"POST {target} HTTP/1.1\r\nHost: localhost\r\n"
                            f"Authorization: {proxy.authorization}\r\n"
                            f"Transfer-Encoding: chunked\r\n{extra}\r\n").encode() + wire_body)
            response = http.client.HTTPResponse(client)
            response.begin()
            status = response.status
            response.read()
            response.close()
            return status
        finally:
            client.close()

    def test_real_restic_empty_chunked_init_and_binary_writes_are_decoded(self):
        seen = []

        def callback(method, path, body, timeout):
            seen.append((method, path, body))
            return 200, {}, b""

        with backup.BackupProxy(callback, time.monotonic() + 10) as proxy:
            self.assertEqual(self.request(proxy, b"0\r\n\r\n", target="/?create=true"), 200)
            self.assertEqual(self.request(proxy, b"2\r\n\x00\xff\r\n3\r\nabc\r\n0\r\n\r\n"), 200)
        self.assertEqual(seen, [
            ("POST", backup.BACKUP_PATH + "/?create=true", b""),
            ("POST", backup.BACKUP_PATH + "/config", b"\x00\xffabc"),
        ])

    def test_ambiguous_headers_chunk_syntax_and_trailers_never_reach_callback(self):
        seen = []
        cases = [
            (b"0\r\n\r\n", "Content-Length: 0\r\n"),
            (b"0\r\n\r\n", "Transfer-Encoding: chunked\r\n"),
            (b"0\r\n\r\n", "Trailer: X-Checksum\r\n"),
            (b"0;extension=value\r\n\r\n", ""),
            (b"+0\r\n\r\n", ""),
            (b" 0\r\n\r\n", ""),
            (b"0\n\r\n", ""),
            (b"000000000\r\n\r\n", ""),
            (b"1\r\nxXX0\r\n\r\n", ""),
            (b"0\r\nX-Checksum: value\r\n\r\n", ""),
        ]
        with backup.BackupProxy(lambda *a, **kw: seen.append(a), time.monotonic() + 10) as proxy:
            for body, extra in cases:
                with self.subTest(body=body, extra=extra):
                    self.assertEqual(self.request(proxy, body, extra), 400)
        self.assertEqual(seen, [])

    def test_decoded_body_and_frame_budgets(self):
        seen = []
        with backup.BackupProxy(lambda *a, **kw: seen.append(a), time.monotonic() + 10) as proxy:
            with patch.object(backup, "MAX_BODY_BYTES", 2):
                # Reject before trying to read an announced oversized frame.
                self.assertEqual(self.request(proxy, b"3\r\nabc\r\n0\r\n\r\n"), 413)
                self.assertEqual(self.request(proxy, b"2\r\nab\r\n1\r\nc\r\n0\r\n\r\n"), 413)
            with patch.object(backup, "MAX_CHUNK_FRAMES", 2):
                self.assertEqual(self.request(proxy, b"1\r\na\r\n1\r\nb\r\n0\r\n\r\n"), 400)
        self.assertEqual(seen, [])

    def test_chunked_body_obeys_absolute_deadline_and_never_forwards_partial_bytes(self):
        seen = []
        began = time.monotonic()
        with backup.BackupProxy(lambda *a, **kw: seen.append(a), began + 0.15) as proxy:
            client = socket.create_connection(("127.0.0.1", proxy.server.server_port), timeout=2)
            try:
                client.sendall((f"POST /config HTTP/1.1\r\nHost: localhost\r\n"
                                f"Authorization: {proxy.authorization}\r\n"
                                "Transfer-Encoding: chunked\r\n\r\n4\r\nx").encode())
                time.sleep(0.25)
            finally:
                client.close()
        self.assertLess(time.monotonic() - began, 2)
        self.assertEqual(seen, [])


class ReviewDocker(FakeDocker):
    def __init__(self):
        super().__init__()
        self.listed_tools = ""
        self.list_ok = True
        self.unpause_failures = 0
        self.unpause_attempts = 0
        self.overrun = None

    def __call__(self, argv, timeout=120):
        if argv[1] == "ps":
            self.calls.append((list(argv), timeout))
            return self.list_ok, self.listed_tools
        if argv[1] == "unpause":
            self.unpause_attempts += 1
            if self.unpause_attempts <= self.unpause_failures:
                self.calls.append((list(argv), timeout))
                return False, "synthetic daemon failure"
        if argv[1] == "run" and "backup" in argv and self.overrun:
            self.overrun()
            self.calls.append((list(argv), timeout))
            return False, "deadline exceeded"
        return super().__call__(argv, timeout)


class BackupReviewTest(unittest.TestCase):
    def setUp(self):
        self.docker = ReviewDocker()

    def run_backup(self, **kwargs):
        return backup.run_backup(payload(), FakeHost(), signed_request=lambda *a, **kw: (200, {}, b""),
                                 proxy_factory=FakeProxy, docker=self.docker, **kwargs)

    def test_read_search_capability_and_readonly_fixed_mounts(self):
        self.run_backup()
        argv = next(argv for argv, _ in self.docker.calls if "backup" in argv)
        self.assertEqual(argv[argv.index("--cap-drop") + 1], "ALL")
        self.assertEqual(argv[argv.index("--cap-add") + 1], "DAC_READ_SEARCH")
        self.assertNotIn("DAC_OVERRIDE", argv)
        self.assertNotIn("--privileged", argv)
        self.assertIn("--read-only", argv)
        self.assertIn("--rm", argv)
        self.assertEqual(argv[argv.index("--network") + 1], "host")
        mounts = [argv[i + 1] for i, value in enumerate(argv) if value == "--mount"]
        self.assertEqual(len(mounts), 5)
        self.assertTrue(all(value.endswith(",readonly") for value in mounts))
        self.assertFalse(any("dst=/data/state" in value for value in mounts))

    def test_proxy_credentials_are_only_in_private_env_file_and_one_connection(self):
        self.run_backup()
        repository = FakeProxy.instances[-1].repository
        commands = [argv for argv, _ in self.docker.calls]
        self.assertFalse(any(repository in " ".join(argv) for argv in commands))
        self.assertFalse(any("synthetic-password" in " ".join(argv) for argv in commands))
        self.assertIn("RESTIC_REPOSITORY=" + repository + "\n", self.docker.env_text)
        self.assertFalse(any(os.path.exists(path) for path in self.docker.temp_paths))
        for argv in commands:
            if argv[1] == "run":
                self.assertIn("rest.connections=1", argv)

    def test_image_is_verified_published_index_digest(self):
        self.assertEqual(backup.RESTIC_IMAGE,
                         "restic/restic@sha256:39d9072fb5651c80d75c7a811612eb60b4c06b32ffe87c2e9f3c7222e1797e76")

    def test_deadline_cap_is_900_seconds(self):
        backup.validate_payload(payload(deadline_seconds=900))
        for deadline in (901, 3600, True):
            with self.subTest(deadline=deadline), self.assertRaises(BadCommand):
                backup.validate_payload(payload(deadline_seconds=deadline))

    def test_overrun_still_gives_ten_seconds_unpause_and_one_retry(self):
        now = [0.0]
        self.docker.overrun = lambda: now.__setitem__(0, 2000.0)
        self.docker.unpause_failures = 1
        with self.assertRaises(backup.BackupFailed) as caught:
            self.run_backup(clock=lambda: now[0])
        self.assertTrue(caught.exception.result["unpaused"])
        self.assertTrue(caught.exception.result["tools_stopped"])
        self.assertEqual(self.docker.unpause_attempts, 2)
        self.assertEqual([timeout for argv, timeout in self.docker.calls if argv[1] == "unpause"], [10, 10])
        self.assertEqual(caught.exception.result["duration_ms"], 2000000)

    def test_two_failed_unpauses_are_not_reported_safe(self):
        self.docker.unpause_failures = 2
        with self.assertRaises(backup.BackupFailed) as caught:
            self.run_backup()
        self.assertEqual(self.docker.unpause_attempts, 2)
        self.assertFalse(caught.exception.result["unpaused"])
        self.assertTrue(caught.exception.result["tools_stopped"])

    def test_tool_cleanup_is_verified_before_unpause(self):
        self.assertTrue(self.run_backup()["tools_stopped"])
        commands = [argv for argv, _ in self.docker.calls]
        verify = next(i for i, argv in enumerate(commands) if argv[1] == "ps")
        unpause = next(i for i, argv in enumerate(commands) if argv[1] == "unpause")
        self.assertLess(verify, unpause)
        self.assertEqual(commands[verify], ["docker", "ps", "-a", "--filter",
                                           backup.BACKUP_TOOL_FILTER, "--format", "{{.Names}}"])

    def test_remaining_tool_or_failed_verification_prevents_unpause(self):
        for mode in ("remaining", "list_failure"):
            self.docker = ReviewDocker()
            if mode == "remaining":
                self.docker.listed_tools = "souls-house-backup-" + "a" * 24
            else:
                self.docker.list_ok = False
            with self.subTest(mode=mode), self.assertRaises(backup.BackupFailed) as caught:
                self.run_backup()
            self.assertFalse(caught.exception.result["unpaused"])
            self.assertFalse(caught.exception.result["tools_stopped"])
            self.assertEqual(self.docker.unpause_attempts, 0)

    def test_recovery_hook_is_after_safe_state_inspection_and_before_pause(self):
        events = []
        docker = self.docker

        def run(argv, timeout=120):
            if argv[1] in ("pause", "inspect"):
                events.append(argv[1])
            return docker(argv, timeout)

        host = FakeHost()
        host.begin_backup_recovery = lambda name: events.append(("marker", name))
        backup.run_backup(payload(), host, signed_request=lambda *a, **kw: (200, {}, b""),
                          docker=run, proxy_factory=FakeProxy)
        marker = events.index(("marker", "agent-pilot-1"))
        self.assertEqual(events[marker - 1], "inspect")
        self.assertEqual(events[marker + 1], "pause")

    def test_refused_preexisting_pause_never_creates_recovery_marker(self):
        self.docker.paused = True
        markers = []
        host = FakeHost()
        host.begin_backup_recovery = markers.append
        with self.assertRaises(BadCommand):
            backup.run_backup(payload(), host, signed_request=lambda *a, **kw: (200, {}, b""),
                              docker=self.docker, proxy_factory=FakeProxy)
        self.assertEqual(markers, [])
        self.assertEqual(self.docker.unpause_attempts, 0)

    def test_system_exit_runs_tool_verification_before_unpause(self):
        docker = self.docker
        live_tools = set()
        interrupted_tool = []

        def run(argv, timeout=120):
            if argv[1] == "run" and "backup" in argv:
                tool = argv[argv.index("--name") + 1]
                interrupted_tool.append(tool)
                live_tools.add(tool)
                docker.calls.append((list(argv), timeout))
                raise SystemExit(143)
            if argv[1:3] == ["rm", "-f"]:
                response = docker(argv, timeout)
                live_tools.difference_update(argv[3:])
                return response
            if argv[1] == "ps":
                docker.calls.append((list(argv), timeout))
                return True, "\n".join(sorted(live_tools))
            return docker(argv, timeout)

        with self.assertRaises(SystemExit) as caught:
            backup.run_backup(payload(), FakeHost(), signed_request=lambda *a, **kw: (200, {}, b""),
                              docker=run, proxy_factory=FakeProxy)
        self.assertEqual(caught.exception.code, 143)
        self.assertEqual(len(interrupted_tool), 1)
        self.assertEqual(live_tools, set())
        commands = [argv for argv, _ in docker.calls]
        removed = next(i for i, argv in enumerate(commands) if argv[1] == "rm")
        verified = next(i for i, argv in enumerate(commands) if argv[1] == "ps")
        unpaused = next(i for i, argv in enumerate(commands) if argv[1] == "unpause")
        self.assertIn(interrupted_tool[0], commands[removed][3:])
        self.assertLess(removed, verified)
        self.assertLess(verified, unpaused)
        self.assertFalse(docker.paused)


class RangeProxyTest(unittest.TestCase):
    TARGET = "/data/" + "a" * 64

    def request(self, proxy, value=None, method="GET", target=None):
        headers = {"Authorization": proxy.authorization}
        if value is not None:
            headers["Range"] = value
        client = http.client.HTTPConnection("127.0.0.1", proxy.server.server_port, timeout=2)
        try:
            client.request(method, target or self.TARGET, body=b"" if method == "POST" else None, headers=headers)
            response = client.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            client.close()

    def test_valid_range_reaches_signed_callback_and_returns_exact_partial_bytes(self):
        seen = []

        def request(method, path, body, timeout, request_headers):
            seen.append((method, path, body, request_headers))
            return 206, {"Content-Range": "bytes 3-6/11", "Content-Length": "4"}, b"defg"

        with backup.BackupProxy(request, time.monotonic() + 10) as proxy:
            status, headers, body = self.request(proxy, "bytes=3-6")
        self.assertEqual(status, 206)
        self.assertEqual(body, b"defg")
        self.assertEqual(headers["Content-Range"], "bytes 3-6/11")
        self.assertEqual(headers["Content-Length"], "4")
        self.assertEqual(seen, [("GET", backup.BACKUP_PATH + self.TARGET, b"", {"Range": "bytes=3-6"})])

    def test_invalid_range_never_calls_signed_transport(self):
        seen = []
        with backup.BackupProxy(lambda *a, **kw: seen.append(a), time.monotonic() + 10) as proxy:
            for value in ("bytes=-4", "bytes=6-3", "bytes=0-1,3-4", "Bytes=0-1",
                          "bytes=0-33554432", "bytes=9223372036854775808-9223372036854775808", "bytes=0 - 1"):
                with self.subTest(value=value):
                    self.assertEqual(self.request(proxy, value)[0], 400)
            self.assertEqual(self.request(proxy, "bytes=0-1", method="POST")[0], 400)
            self.assertEqual(self.request(proxy, "bytes=0-1", target="/data/")[0], 400)
        self.assertEqual(seen, [])

    def test_real_restic_open_range_is_bounded_by_signed_head_then_forwarded_closed(self):
        seen = []

        def request(method, path, body, timeout, request_headers=None):
            seen.append((method, path, request_headers))
            if method == "HEAD":
                return 200, {"Content-Length": "11"}, b""
            return 206, {"Content-Range": "bytes 3-10/11"}, b"defghijk"

        with backup.BackupProxy(request, time.monotonic() + 10) as proxy:
            status, headers, body = self.request(proxy, "bytes=3-")
        self.assertEqual(status, 206)
        self.assertEqual(body, b"defghijk")
        self.assertEqual(headers["Content-Range"], "bytes 3-10/11")
        self.assertEqual(seen, [
            ("HEAD", backup.BACKUP_PATH + self.TARGET, None),
            ("GET", backup.BACKUP_PATH + self.TARGET, {"Range": "bytes=3-10"}),
        ])

    def test_open_range_invalid_or_unbounded_head_never_issues_get(self):
        for reply in ((200, {}, b""), (200, {"Content-Length": "3"}, b""),
                      (200, {"Content-Length": str(backup.MAX_BODY_BYTES + 1)}, b""),
                      (404, {"Content-Length": "11"}, b""),
                      (200, {"Content-Length": "11"}, b"unexpected")):
            seen = []

            def request(method, *args, **kwargs):
                seen.append(method)
                return reply

            with self.subTest(reply=reply), backup.BackupProxy(request, time.monotonic() + 10) as proxy:
                self.assertEqual(self.request(proxy, "bytes=3-")[0], 502)
            self.assertEqual(seen, ["HEAD"])

    def test_duplicate_range_headers_refused(self):
        seen = []
        with backup.BackupProxy(lambda *a, **kw: seen.append(a), time.monotonic() + 10) as proxy:
            client = socket.create_connection(("127.0.0.1", proxy.server.server_port), timeout=2)
            try:
                client.sendall((f"GET {self.TARGET} HTTP/1.1\r\nHost: localhost\r\n"
                                f"Authorization: {proxy.authorization}\r\n"
                                "Range: bytes=0-1\r\nRange: bytes=0-1\r\n\r\n").encode())
                response = http.client.HTTPResponse(client)
                response.begin()
                self.assertEqual(response.status, 400)
                response.read()
                response.close()
            finally:
                client.close()
        self.assertEqual(seen, [])

    def test_200_missing_invalid_or_mismatched_ranges_are_never_silently_consumed(self):
        cases = [
            (200, {"Content-Range": "bytes 3-6/11"}, b"abcdefghijk"),
            (206, {}, b"defg"),
            (206, {"Content-Range": "bytes 3-6/*"}, b"defg"),
            (206, {"Content-Range": "bytes 2-5/11"}, b"cdef"),
            (206, {"Content-Range": "bytes 3-5/11"}, b"def"),
            (206, {"Content-Range": "bytes 3-6/6"}, b"defg"),
            (206, {"Content-Range": "bytes 3-6/11"}, b"def"),
            (206, {"Content-Range": "bytes 3-6/11", "Content-Length": "5"}, b"defg"),
            (206, {"Content-Range": "bytes 3-6/11, bytes 3-6/11"}, b"defg"),
            (206, {"Content-Range": "bytes 3-6/11\r\nInjected: header"}, b"defg"),
        ]
        for reply in cases:
            with self.subTest(reply=reply):
                with backup.BackupProxy(lambda *a, **kw: reply, time.monotonic() + 10) as proxy:
                    status, headers, body = self.request(proxy, "bytes=3-6")
                self.assertEqual(status, 502)
                self.assertEqual(body, b"")
                self.assertNotIn("Content-Range", headers)

    def test_unsolicited_206_rejected_and_normal_callbacks_need_no_new_kwarg(self):
        with backup.BackupProxy(lambda m, p, b, timeout: (200, {}, b"whole"), time.monotonic() + 10) as proxy:
            self.assertEqual(self.request(proxy)[2], b"whole")
        with backup.BackupProxy(lambda *a, **kw: (206, {}, b"part"), time.monotonic() + 10) as proxy:
            self.assertEqual(self.request(proxy)[0], 502)


class SignedRangeTransportTest(unittest.TestCase):
    def call(self, status=206, headers=None, body=b"defg", request_headers=None):
        seen = {}
        response_headers = headers if headers is not None else {"Content-Range": "bytes 3-6/11", "Content-Length": "4"}

        class Sock:
            def settimeout(self, timeout):
                pass

            def shutdown(self, how):
                pass

        class Response:
            def __init__(self):
                self.status = status
                self.body = body

            def getheader(self, key, default=None):
                return response_headers.get(key, default)

            def read1(self, size):
                chunk, self.body = self.body[:size], self.body[size:]
                return chunk

        class Connection:
            sock = Sock()

            def __init__(self, *args, **kwargs):
                pass

            def connect(self):
                pass

            def request(self, method, path, body, headers):
                seen["headers"] = headers

            def getresponse(self):
                return Response()

            def close(self):
                seen["closed"] = True

        def sign(key, method, path, body, runner_id):
            seen["signed"] = (method, path, body, runner_id)
            return {"X-Runner-Signature": "synthetic"}

        with patch.object(backup.http.client, "HTTPSConnection", Connection):
            request = backup.make_signed_request({"rails_url": "https://house.invalid", "runner_id": "synthetic"},
                                                 None, sign)
            reply = request("GET", backup.BACKUP_PATH + RangeProxyTest.TARGET, b"",
                            request_headers={"Range": "bytes=3-6"} if request_headers is None else request_headers)
        return reply, seen

    def test_transport_forwards_range_but_does_not_change_signature_contract(self):
        reply, seen = self.call()
        self.assertEqual(reply[0], 206)
        self.assertEqual(reply[2], b"defg")
        self.assertEqual(seen["headers"]["Range"], "bytes=3-6")
        self.assertEqual(seen["signed"], ("GET", backup.BACKUP_PATH + RangeProxyTest.TARGET, b"", "synthetic"))
        self.assertTrue(seen["closed"])

    def test_transport_independently_checks_partial_response(self):
        for status, headers, body in ((200, {}, b"abcdefghijk"), (206, {}, b"defg"),
                                     (206, {"Content-Range": "bytes 2-5/11"}, b"cdef"),
                                     (206, {"Content-Range": "bytes 3-6/11"}, b"def")):
            with self.subTest(status=status, headers=headers), self.assertRaises(ValueError):
                self.call(status, headers, body)

    def test_transport_does_not_accept_arbitrary_request_headers(self):
        for headers in ({"Range": "bytes=3-"}, {"Range": "bytes=3-6", "Authorization": "evil"},
                        {"X-Runner-Id": "other"}, {"Range": None}, []):
            with self.subTest(headers=headers), self.assertRaises(BadCommand):
                self.call(request_headers=headers)


class BoundedDockerTest(unittest.TestCase):
    def test_system_exit_kills_and_reaps_docker_client_before_propagating(self):
        class Process:
            stdout = io.BytesIO()
            stderr = io.BytesIO()
            code = None
            waits = 0
            kills = 0

            def wait(self, timeout=None):
                self.waits += 1
                if self.waits == 1:
                    raise SystemExit(143)
                return self.code

            def poll(self):
                return self.code

            def kill(self):
                self.kills += 1
                self.code = -9

        process = Process()
        with patch.object(backup.subprocess, "Popen", return_value=process):
            with self.assertRaises(SystemExit) as caught:
                backup.bounded_docker(["docker", "run", "synthetic"])
        self.assertEqual(caught.exception.code, 143)
        self.assertEqual(process.kills, 1)
        self.assertEqual(process.waits, 2)

    def test_output_tail_bounded(self):
        ok, output = backup.bounded_docker([sys.executable, "-c", "print('x' * 300000)"], timeout=2)
        self.assertTrue(ok)
        self.assertLessEqual(len(output), backup.OUTPUT_BYTES)

    def test_failed_command_returns_stderr_not_stdout(self):
        ok, output = backup.bounded_docker([
            sys.executable, "-c",
            "import sys; print('stdout decoy'); "
            "print('config file already exists', file=sys.stderr); sys.exit(1)",
        ], timeout=2)
        self.assertFalse(ok)
        self.assertEqual(output, "config file already exists")

    def test_timeout_kills_and_reaps_process(self):
        before = time.monotonic()
        ok, output = backup.bounded_docker([sys.executable, "-c", "import time; time.sleep(10)"], timeout=0.05)
        self.assertFalse(ok)
        self.assertIn("deadline", output)
        self.assertLess(time.monotonic() - before, 2)


if __name__ == "__main__":
    unittest.main()
