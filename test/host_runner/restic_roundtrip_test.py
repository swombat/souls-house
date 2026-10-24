"""Optional published-restic integration check, with synthetic local storage.

Set RESTIC_TEST_BINARY to an independently checksum-verified restic executable.
No Docker, S3/provider credentials or cloud instance is used by this check.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.parse import urlsplit

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "host-runner"))
import backup_proxy as backup


@unittest.skipUnless(os.environ.get("RESTIC_TEST_BINARY"), "published restic executable not supplied")
class ResticRoundtripTest(unittest.TestCase):
    def test_two_backups_and_restore_through_signing_proxy(self):
        objects = {}
        ranges = []

        def request(method, fullpath, body, timeout=None, request_headers=None):
            path = urlsplit(fullpath).path.removeprefix(backup.BACKUP_PATH).lstrip("/")
            if method == "POST":
                if not path:
                    return 200, {}, b""
                if path in objects and objects[path] != body:
                    return 409, {}, b""
                objects[path] = body
                return 200, {}, b""
            if method == "DELETE":
                self.assertTrue(path.startswith("locks/"))
                objects.pop(path, None)
                return 200, {}, b""
            if method == "GET" and path.endswith("/"):
                # REST v1 listing. All names remain flat on the wire.
                names = [key[len(path):] for key in objects if key.startswith(path)]
                return 200, {}, json.dumps(names).encode()
            if path not in objects:
                return 404, {}, b""
            data = objects[path]
            if method == "HEAD":
                return 200, {"Content-Length": str(len(data))}, b""
            value = (request_headers or {}).get("Range")
            if value:
                bounds = re.fullmatch(r"bytes=(\d+)-(\d+)", value)
                self.assertIsNotNone(bounds)
                start, end = map(int, bounds.groups())
                ranges.append(value)
                part = data[start:end + 1]
                return 206, {"Content-Range": f"bytes {start}-{end}/{len(data)}",
                             "Content-Length": str(len(part))}, part
            return 200, {"Content-Length": str(len(data))}, data

        with tempfile.TemporaryDirectory() as root, backup.BackupProxy(request, time.monotonic() + 120) as proxy:
            observed = []
            handler = proxy.server.RequestHandlerClass
            original_relay = handler.relay

            def relay(instance):
                observed.append((instance.command, instance.path,
                                 {name: instance.headers.get(name) for name in
                                  ("Content-Length", "Transfer-Encoding", "Expect", "Range")}))
                return original_relay(instance)

            for method in ("GET", "POST", "HEAD", "DELETE"):
                setattr(handler, "do_" + method, relay)
            home = os.path.join(root, "home")
            os.mkdir(home)
            source = os.path.join(root, "private.txt")
            with open(source, "wb") as handle:
                handle.write(b"synthetic-private-bytes\n" * 1000)
            os.chmod(source, 0o600)
            environment = {"PATH": "/usr/bin:/bin", "HOME": home,
                           "RESTIC_PASSWORD": "synthetic-restic-test-password",
                           "RESTIC_REPOSITORY": proxy.repository}

            def restic(*args):
                result = subprocess.run([os.environ["RESTIC_TEST_BINARY"], "--no-cache",
                                         "-o", "rest.connections=1", *args],
                                        env=environment, capture_output=True, timeout=40)
                self.assertEqual(0, result.returncode, result.stderr.decode() + repr(observed))
                return result.stdout

            restic("init")
            # The runner initializes on every backup attempt. Verify the pinned
            # executable's real existing-repository error, not a mock phrase.
            repeated_init = subprocess.run(
                [os.environ["RESTIC_TEST_BINARY"], "--no-cache",
                 "-o", "rest.connections=1", "init"],
                env=environment, capture_output=True, timeout=40,
            )
            self.assertEqual(1, repeated_init.returncode)
            self.assertEqual(b"", repeated_init.stdout)
            # Exercise the same matcher run_backup uses, with untouched stderr.
            self.assertTrue(backup.restic_config_exists(repeated_init.stderr.decode()))
            restic("backup", source, "--json")
            # Same file/path makes the second backup read its parent's pack.
            output = restic("backup", source, "--json")
            summary = next(json.loads(line) for line in output.splitlines()
                           if json.loads(line).get("message_type") == "summary")
            restored = restic("dump", summary["snapshot_id"], source)
            self.assertEqual(b"synthetic-private-bytes\n" * 1000, restored)
            self.assertTrue(ranges, "real restic must exercise ranged parent/pack reads")
