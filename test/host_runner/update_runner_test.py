import hashlib
import io
import os
import shutil
import sys
import tarfile
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "host-runner"))

import souls_house_runner as runner  # noqa: E402
from commands_test import FakeDocker, FakeHttp  # noqa: E402


def bundle(files=None):
    files = files if files is not None else {"souls_house_runner.py": b"VERSION = 2\n", "backup_proxy.py": b"X = 1\n"}
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w:xz") as archive:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    data = raw.getvalue()
    return data, hashlib.sha256(data).hexdigest()


class UpdateRunnerTest(unittest.TestCase):
    """The house can replace a VM's runner through the command queue (#593):
    by digest, checked, self-checked, swapped with the marker last."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.runner_dir = tempfile.mkdtemp()
        for name in runner.RUNNER_BUNDLE_FILES:
            with open(os.path.join(self.runner_dir, name), "w") as handle:
                handle.write("OLD = True\n")
        self.served = {}
        self.fetched = []
        self.checked = []
        self.self_check_ok = True

        def fetch(digest, write):
            self.fetched.append(digest)
            if digest not in self.served:
                return False, "house answered 404"
            write(self.served[digest])
            return True, ""

        def self_check(directory):
            self.checked.append(sorted(os.listdir(directory)))
            return self.self_check_ok

        self.host = runner.ResidentHost(self.dir, docker=FakeDocker(), http=FakeHttp(), sleep=lambda s: None,
                                        fetch_runner_bundle=fetch, runner_dir=self.runner_dir, self_check=self_check)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)
        shutil.rmtree(self.runner_dir, ignore_errors=True)

    def read(self, name):
        with open(os.path.join(self.runner_dir, name)) as handle:
            return handle.read()

    def leftovers(self):
        return [name for name in os.listdir(self.runner_dir) if name.startswith(".update-")]

    def test_installs_the_bundle_marks_it_and_asks_for_a_restart(self):
        data, digest = bundle()
        self.served[digest] = data
        result = self.host.update_runner({"sha256": digest, "bytes": len(data)})
        self.assertEqual({"state": "installed", "sha256": digest}, result)
        self.assertEqual("VERSION = 2\n", self.read("souls_house_runner.py"))
        self.assertEqual("X = 1\n", self.read("backup_proxy.py"))
        self.assertEqual(digest, runner.installed_runner_bundle(self.runner_dir))
        self.assertEqual(0o755, os.stat(os.path.join(self.runner_dir, "souls_house_runner.py")).st_mode & 0o777)
        self.assertEqual([["backup_proxy.py", "souls_house_runner.py"]], self.checked)
        self.assertTrue(self.host.restart_requested)
        self.assertEqual([], self.leftovers())

    def test_a_retry_for_the_installed_bundle_is_already_done_and_fetches_nothing(self):
        data, digest = bundle()
        self.served[digest] = data
        self.host.update_runner({"sha256": digest, "bytes": len(data)})
        self.host.restart_requested = False
        self.fetched.clear()
        result = self.host.update_runner({"sha256": digest, "bytes": len(data)})
        self.assertEqual({"state": "current", "sha256": digest, "already": True}, result)
        self.assertEqual([], self.fetched)
        self.assertFalse(self.host.restart_requested)

    def assert_untouched(self):
        self.assertEqual("OLD = True\n", self.read("souls_house_runner.py"))
        self.assertEqual("OLD = True\n", self.read("backup_proxy.py"))
        self.assertIsNone(runner.installed_runner_bundle(self.runner_dir))
        self.assertFalse(self.host.restart_requested)
        self.assertEqual([], self.leftovers())

    def test_bytes_that_do_not_match_the_digest_are_refused(self):
        data, digest = bundle()
        other, _ = bundle({"souls_house_runner.py": b"EVIL = 1\n", "backup_proxy.py": b"X = 1\n"})
        self.served[digest] = other
        with self.assertRaises(runner.CommandFailed):
            self.host.update_runner({"sha256": digest, "bytes": len(other)})
        self.assert_untouched()

    def test_more_bytes_than_announced_are_refused(self):
        data, digest = bundle()
        self.served[digest] = data
        with self.assertRaises(runner.CommandFailed):
            self.host.update_runner({"sha256": digest, "bytes": len(data) - 1})
        self.assert_untouched()

    def test_a_bundle_with_other_files_or_missing_ones_is_refused(self):
        for files in ({"souls_house_runner.py": b"A = 1\n"},
                      {"souls_house_runner.py": b"A = 1\n", "backup_proxy.py": b"B = 1\n", "evil.py": b"C = 1\n"},
                      {"souls_house_runner.py": b"A = 1\n", "../backup_proxy.py": b"B = 1\n"}):
            with self.subTest(files=sorted(files)):
                data, digest = bundle(files)
                self.served[digest] = data
                with self.assertRaises(runner.BadCommand):
                    self.host.update_runner({"sha256": digest, "bytes": len(data)})
                self.assert_untouched()

    def test_source_that_does_not_compile_is_refused(self):
        data, digest = bundle({"souls_house_runner.py": b"def broken(:\n", "backup_proxy.py": b"X = 1\n"})
        self.served[digest] = data
        with self.assertRaises(runner.BadCommand):
            self.host.update_runner({"sha256": digest, "bytes": len(data)})
        self.assert_untouched()

    def test_a_failed_self_check_keeps_the_old_runner(self):
        data, digest = bundle()
        self.served[digest] = data
        self.self_check_ok = False
        with self.assertRaises(runner.CommandFailed):
            self.host.update_runner({"sha256": digest, "bytes": len(data)})
        self.assert_untouched()

    def test_a_failed_fetch_keeps_the_old_runner(self):
        _, digest = bundle()
        with self.assertRaises(runner.CommandFailed):
            self.host.update_runner({"sha256": digest, "bytes": 100})
        self.assert_untouched()

    def test_bad_payloads_are_refused(self):
        for payload in ({}, {"sha256": "abc", "bytes": 10}, {"sha256": "0" * 64, "bytes": 0},
                        {"sha256": "0" * 64, "bytes": True},
                        {"sha256": "0" * 64, "bytes": runner.RUNNER_BUNDLE_MAX_BYTES + 1}):
            with self.subTest(payload=payload), self.assertRaises(runner.BadCommand):
                self.host.update_runner(payload)

    def test_the_real_self_check_accepts_this_runner_and_rejects_a_broken_one(self):
        good = tempfile.mkdtemp()
        bad = tempfile.mkdtemp()
        try:
            source_dir = os.path.join(HERE, "..", "..", "host-runner")
            for name in runner.RUNNER_BUNDLE_FILES:
                shutil.copy(os.path.join(source_dir, name), os.path.join(good, name))
                shutil.copy(os.path.join(source_dir, name), os.path.join(bad, name))
            with open(os.path.join(bad, "backup_proxy.py"), "a") as handle:
                handle.write("\nraise RuntimeError('broken on import')\n")
            self.assertTrue(runner._runner_self_check(good))
            self.assertFalse(runner._runner_self_check(bad))
        finally:
            shutil.rmtree(good, ignore_errors=True)
            shutil.rmtree(bad, ignore_errors=True)

    def test_an_invalid_marker_counts_as_no_bundle(self):
        self.assertIsNone(runner.installed_runner_bundle(self.runner_dir))
        with open(os.path.join(self.runner_dir, runner.RUNNER_BUNDLE_MARKER), "w") as handle:
            handle.write("not a digest\n")
        self.assertIsNone(runner.installed_runner_bundle(self.runner_dir))

    def test_update_runner_is_in_the_vocabulary(self):
        self.assertIn("update_runner", runner.COMMAND_KINDS)


if __name__ == "__main__":
    unittest.main()
