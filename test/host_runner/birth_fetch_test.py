"""birth_fetch.py (#779) against a local fake origin.

Harness evidence, not a VM: the origin is plain HTTP on loopback through an
injected connection factory (production uses HTTPSConnection, and
origin_parts refuses anything but a bare https origin); systemd is not run,
so retries are modelled as repeated main() calls, and its unit's settings are
asserted in RunnerUserDataTest.
"""
import contextlib
import hashlib
import http.client
import http.server
import io
import json
import os
import socket
import sys
import tarfile
import tempfile
import threading
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "host-runner"))

import birth_fetch  # noqa: E402

TOKEN = "tok_" + "s" * 40
RUNNER_ID = "rnr_0123456789abcdef0123"


def bundle(files=None, symlink=None):
    files = files if files is not None else {"souls_house_runner.py": b"VERSION = 2\n", "backup_proxy.py": b"X = 1\n"}
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w:xz") as archive:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        if symlink:
            info = tarfile.TarInfo(symlink)
            info.type = tarfile.SYMTYPE
            info.linkname = "/etc/passwd"
            archive.addfile(info)
    data = raw.getvalue()
    return data, hashlib.sha256(data).hexdigest()


class Origin:
    """Answers each request with the next queued (status, headers, body) or a
    callable; records the requests it saw."""

    def __init__(self):
        self.responses = []
        self.requests = []
        origin = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                origin.requests.append((self.path, dict(self.headers)))
                answer = origin.responses.pop(0) if origin.responses else (404, {}, b"")
                if callable(answer):
                    return answer(self)
                status, headers, body = answer
                self.send_response(status)
                for key, value in headers.items():
                    self.send_header(key, value)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def connection(self, host, port, timeout):
        return http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=timeout)

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class BirthFetchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.runner_dir = os.path.join(self.root, "opt")
        os.mkdir(self.runner_dir)
        self.started = os.path.join(self.root, "state", "fetch-started")
        self.data, self.digest = bundle()
        self.config = os.path.join(self.root, "config.json")
        with open(self.config, "w") as handle:
            json.dump({"rails_url": "https://souls.example", "runner_id": RUNNER_ID,
                       "enrollment_token": TOKEN, "birth_bundle_sha256": self.digest}, handle)
        self.origin = Origin()
        self.starts = 0

    def tearDown(self):
        self.origin.close()
        self.tmp.cleanup()

    def start(self):
        self.starts += 1

    def main(self, wall=time.time):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = birth_fetch.main(config_path=self.config, runner_dir=self.runner_dir,
                                    started_path=self.started, wall=wall, start=self.start,
                                    connection=self.origin.connection)
        self.assertNotIn(TOKEN, stderr.getvalue())
        return code, stderr.getvalue()

    def assert_nothing_installed(self):
        self.assertFalse(os.path.lexists(os.path.join(self.runner_dir, "current")))
        self.assertFalse(birth_fetch.installed(self.runner_dir, self.digest))

    def test_installs_the_pinned_pair_behind_current_and_starts_the_runner(self):
        self.origin.responses.append((200, {}, self.data))
        code, _ = self.main()
        self.assertEqual(0, code)
        self.assertEqual(1, self.starts)
        self.assertTrue(birth_fetch.installed(self.runner_dir, self.digest))
        path, headers = self.origin.requests[0]
        self.assertEqual("/api/v1/host_runner/birth_bundles/" + self.digest, path)
        self.assertEqual("Bearer " + TOKEN, headers["Authorization"])
        self.assertEqual(RUNNER_ID, headers["X-Runner-Id"])
        self.assertNotIn(TOKEN, path)
        for name, mode in birth_fetch.FILES.items():
            entry = os.path.join(self.runner_dir, name)
            self.assertEqual(os.path.join("current", name), os.readlink(entry))
            self.assertEqual(mode, os.stat(entry).st_mode & 0o777)
        with open(os.path.join(self.runner_dir, "souls_house_runner.py"), "rb") as handle:
            self.assertEqual(b"VERSION = 2\n", handle.read())
        self.assertTrue(os.readlink(os.path.join(self.runner_dir, "current")).startswith("versions/" + self.digest + "-"))

    def test_already_installed_only_starts_the_runner(self):
        self.origin.responses.append((200, {}, self.data))
        self.main()
        code, _ = self.main()
        self.assertEqual(0, code)
        self.assertEqual(1, len(self.origin.requests))
        self.assertEqual(2, self.starts)

    def test_refuses_bytes_that_do_not_match_the_pinned_digest(self):
        other, _ = bundle({"souls_house_runner.py": b"EVIL = 1\n", "backup_proxy.py": b"X = 1\n"})
        self.origin.responses.append((200, {}, other))
        code, err = self.main()
        self.assertEqual(1, code)
        self.assertIn("digest mismatch", err)
        self.assert_nothing_installed()
        self.assertEqual(0, self.starts)

    def test_follows_no_redirect(self):
        self.origin.responses.append((302, {"Location": "/elsewhere"}, b""))
        self.origin.responses.append((200, {}, self.data))
        code, err = self.main()
        self.assertEqual(1, code)
        self.assertIn("status 302", err)
        self.assertEqual(1, len(self.origin.requests))
        self.assert_nothing_installed()

    def test_refuses_an_oversize_body_without_reading_past_the_cap(self):
        self.origin.responses.append((200, {}, b"x" * (birth_fetch.MAX_BYTES + 10)))
        code, err = self.main()
        self.assertEqual(1, code)
        self.assertIn("too large", err)
        self.assert_nothing_installed()

    def test_refuses_bad_members_whole(self):
        for files, symlink in [
            ({"souls_house_runner.py": b"A = 1\n", "backup_proxy.py": b"X = 1\n", "extra.py": b""}, None),
            ({"souls_house_runner.py": b"A = 1\n"}, None),
            ({"souls_house_runner.py": b"def (\n", "backup_proxy.py": b"X = 1\n"}, None),
            ({"souls_house_runner.py": b"A = 1\n", "backup_proxy.py": b"X = 1\n"}, "../escape"),
        ]:
            data, digest = bundle(files, symlink)
            with self.subTest(files=sorted(files), symlink=symlink):
                with self.assertRaises(birth_fetch.Failed):
                    birth_fetch.unpack(data)

    def test_an_origin_that_accepts_then_stalls_costs_one_bounded_attempt(self):
        def stall(handler):
            time.sleep(5)

        self.origin.responses.append(stall)
        with mock.patch.object(birth_fetch, "ATTEMPT_SECONDS", 1.0), mock.patch.object(birth_fetch, "READ_SECONDS", 30):
            began = time.monotonic()
            code, err = self.main()
            elapsed = time.monotonic() - began
        self.assertEqual(1, code)
        self.assertLess(elapsed, 2.5)
        self.assert_nothing_installed()

    def trickle(self, head, tail):
        """A peer that sends `head`, then one byte of `tail` every 0.04 s:
        never idle for a read timeout, so only the attempt clock can end it."""
        def answer(handler):
            try:
                handler.wfile.write(head)
                handler.wfile.flush()
                for byte in tail:
                    handler.wfile.write(bytes([byte]))
                    handler.wfile.flush()
                    time.sleep(0.04)
            except OSError:
                pass

        self.origin.responses.append(answer)
        with mock.patch.object(birth_fetch, "ATTEMPT_SECONDS", 0.5), mock.patch.object(birth_fetch, "READ_SECONDS", 30):
            began = time.monotonic()
            code, err = self.main()
            elapsed = time.monotonic() - began
        self.assertEqual(1, code)
        self.assertIn("attempt deadline", err)
        self.assertLess(elapsed, 1.2)
        self.assert_nothing_installed()

    def test_trickling_headers_end_at_the_attempt_deadline(self):
        self.trickle(b"HTTP/1.1 200 OK\r\n", b"X-Slow: " + b"y" * 200 + b"\r\n\r\n")

    def test_a_trickling_body_ends_at_the_attempt_deadline(self):
        self.trickle(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(self.data), self.data * 4)

    def test_a_failed_attempt_then_a_later_one_installs_and_starts(self):
        self.origin.responses.append((503, {}, b""))
        self.assertEqual(1, self.main()[0])
        self.assertEqual(0, self.starts)
        self.origin.responses.append((200, {}, self.data))
        self.assertEqual(0, self.main()[0])
        self.assertEqual(1, self.starts)
        self.assertTrue(birth_fetch.installed(self.runner_dir, self.digest))

    def test_gives_up_with_exit_3_once_the_bound_has_passed_since_the_first_attempt(self):
        clock = [1_000_000.0]
        wall = lambda: clock[0]  # noqa: E731
        self.origin.responses.append((503, {}, b""))
        self.assertEqual(1, self.main(wall)[0])
        # A reboot (fresh process) keeps the recorded first attempt.
        clock[0] += birth_fetch.GIVE_UP_AFTER - 1
        self.origin.responses.append((503, {}, b""))
        self.assertEqual(1, self.main(wall)[0])
        clock[0] += 2
        code, err = self.main(wall)
        self.assertEqual(birth_fetch.GAVE_UP, code)
        self.assertEqual(2, len(self.origin.requests))
        with open(self.started) as handle:
            self.assertEqual(1_000_000.0, float(handle.read()))

    def test_an_interrupted_install_is_never_seen_as_installed_and_the_next_start_recovers(self):
        files = birth_fetch.unpack(self.data)
        real_rename, real_point = os.rename, birth_fetch._point

        class Killed(BaseException):
            pass

        def kill_rename(*args):
            raise Killed()

        def kill_point_current(directory, name, target):
            if name == "current":
                raise Killed()
            return real_point(directory, name, target)

        for label, patch in [("after stage", mock.patch.object(birth_fetch.os, "rename", kill_rename)),
                             ("before link swap", mock.patch.object(birth_fetch, "_point", kill_point_current))]:
            with self.subTest(step=label):
                with patch, self.assertRaises(Killed):
                    birth_fetch.install(self.runner_dir, self.digest, files)
                self.assertFalse(birth_fetch.installed(self.runner_dir, self.digest))
                self.assertFalse(os.path.lexists(os.path.join(self.runner_dir, "current")))
        self.assertIs(os.rename, real_rename)
        self.origin.responses.append((200, {}, self.data))
        self.assertEqual(0, self.main()[0])
        self.assertTrue(birth_fetch.installed(self.runner_dir, self.digest))
        leftovers = [n for n in os.listdir(os.path.join(self.runner_dir, "versions")) if n.startswith(".stage-")]
        self.assertEqual([], leftovers)

    def test_an_exception_is_reported_by_class_never_by_message(self):
        def boom(*args, **kwargs):
            raise RuntimeError("Authorization: Bearer " + TOKEN)

        with mock.patch.object(birth_fetch, "fetch", boom):
            code, err = self.main()
        self.assertEqual(1, code)
        self.assertIn("RuntimeError", err)

    def test_refuses_anything_but_a_bare_https_origin(self):
        for url in ["http://souls.example", "https://u:p@souls.example", "https://souls.example/x",
                    "https://souls.example?q", "https://"]:
            with self.subTest(url=url), self.assertRaises(birth_fetch.Failed):
                birth_fetch.origin_parts(url)
        self.assertEqual(("souls.example", 443), birth_fetch.origin_parts("https://souls.example/"))

    def test_refuses_a_malformed_pinned_digest_without_fetching(self):
        with open(self.config, "w") as handle:
            json.dump({"rails_url": "https://souls.example", "runner_id": RUNNER_ID,
                       "enrollment_token": TOKEN, "birth_bundle_sha256": "../../etc"}, handle)
        code, err = self.main()
        self.assertEqual(1, code)
        self.assertEqual([], self.origin.requests)


if __name__ == "__main__":
    unittest.main()
