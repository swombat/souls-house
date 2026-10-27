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
        versions = os.path.join(self.runner_dir, runner.RUNNER_VERSIONS)
        staged = [name for name in os.listdir(versions) if name.startswith(runner.RUNNER_STAGE_PREFIX)] \
            if os.path.isdir(versions) else []
        return staged + [name for name in os.listdir(self.runner_dir) if name.startswith(".")]

    def pair(self):
        return self.read("souls_house_runner.py"), self.read("backup_proxy.py")

    def test_installs_the_bundle_marks_it_and_asks_for_a_restart(self):
        data, digest = bundle()
        self.served[digest] = data
        result = self.host.update_runner({"sha256": digest, "bytes": len(data)})
        self.assertEqual({"state": "installed", "sha256": digest}, result)
        self.assertEqual("VERSION = 2\n", self.read("souls_house_runner.py"))
        self.assertEqual("X = 1\n", self.read("backup_proxy.py"))
        self.assertEqual(digest, runner.installed_runner_bundle(self.runner_dir))
        self.assertEqual(0o755, os.stat(os.path.join(self.runner_dir, "souls_house_runner.py")).st_mode & 0o777)
        for name in runner.RUNNER_BUNDLE_FILES:
            self.assertEqual(os.path.join("current", name), os.readlink(os.path.join(self.runner_dir, name)))
        # The birth pair is kept, behind `previous`.
        with open(os.path.join(self.runner_dir, "previous", "backup_proxy.py")) as handle:
            self.assertEqual("OLD = True\n", handle.read())
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
        data, digest = bundle()
        self.served[digest] = data
        self.host.update_runner({"sha256": digest, "bytes": len(data)})
        marker = os.path.join(self.runner_dir, "current", runner.RUNNER_BUNDLE_MARKER)
        os.chmod(marker, 0o644)
        with open(marker, "w") as handle:
            handle.write("not a digest\n")
        self.assertIsNone(runner.installed_runner_bundle(self.runner_dir))

    def test_a_second_update_keeps_exactly_the_previous_pair(self):
        first, first_digest = bundle({"souls_house_runner.py": b"V = 1\n", "backup_proxy.py": b"B = 1\n"})
        second, second_digest = bundle({"souls_house_runner.py": b"V = 2\n", "backup_proxy.py": b"B = 2\n"})
        self.served.update({first_digest: first, second_digest: second})
        self.host.update_runner({"sha256": first_digest, "bytes": len(first)})
        self.host.update_runner({"sha256": second_digest, "bytes": len(second)})
        self.assertEqual(("V = 2\n", "B = 2\n"), self.pair())
        self.assertEqual(second_digest, runner.installed_runner_bundle(self.runner_dir))
        with open(os.path.join(self.runner_dir, "previous", "backup_proxy.py")) as handle:
            self.assertEqual("B = 1\n", handle.read())
        self.assertEqual(2, len(os.listdir(os.path.join(self.runner_dir, runner.RUNNER_VERSIONS))))
        self.assertEqual([], self.leftovers())

    def test_a_fault_at_any_filesystem_step_leaves_a_matched_pair_and_a_retry_installs(self):
        # Mira's P1 (#615): a failure or a killed process between two file
        # replacements must never leave a new runner beside an old backup
        # module. Fail each rename/link/replace of a successful update in
        # turn, as an exception and as a process death (no cleanup runs),
        # then check what systemd would start, then retry cleanly.
        data, digest = bundle()
        self.served[digest] = data
        real = {name: getattr(os, name) for name in ("replace", "rename", "symlink")}
        calls = []

        def counting(name):
            def call(*args, **kwargs):
                calls.append(name)
                return real[name](*args, **kwargs)
            return call

        probe_dir = tempfile.mkdtemp()
        try:
            for name in runner.RUNNER_BUNDLE_FILES:
                shutil.copy(os.path.join(self.runner_dir, name), os.path.join(probe_dir, name))
            probe = runner.ResidentHost(self.dir, docker=FakeDocker(), http=FakeHttp(), sleep=lambda s: None,
                                        fetch_runner_bundle=lambda d, w: (w(data), (True, ""))[1],
                                        runner_dir=probe_dir, self_check=lambda d: True)
            for name in real:
                setattr(os, name, counting(name))
            try:
                probe.update_runner({"sha256": digest, "bytes": len(data)})
            finally:
                for name, function in real.items():
                    setattr(os, name, function)
        finally:
            shutil.rmtree(probe_dir, ignore_errors=True)
        self.assertGreaterEqual(len(calls), 5)

        class Died(BaseException):
            pass

        for death in (False, True):
            for step in range(len(calls)):
                with self.subTest(step=step, death=death):
                    shutil.rmtree(self.runner_dir)
                    os.mkdir(self.runner_dir)
                    for name in runner.RUNNER_BUNDLE_FILES:
                        with open(os.path.join(self.runner_dir, name), "w") as handle:
                            handle.write("OLD = True\n")
                    self.host.restart_requested = False
                    seen = []

                    def faulty(name):
                        def call(*args, **kwargs):
                            seen.append(name)
                            if len(seen) - 1 == step:
                                if death:
                                    raise Died()
                                raise OSError(5, "injected EIO")
                            return real[name](*args, **kwargs)
                        return call

                    rmtree = shutil.rmtree
                    for name in real:
                        setattr(os, name, faulty(name))
                    if death:
                        shutil.rmtree = lambda *a, **k: None  # a dead process cleans nothing
                    try:
                        with self.assertRaises((OSError, Died)):
                            self.host.update_runner({"sha256": digest, "bytes": len(data)})
                    finally:
                        for name, function in real.items():
                            setattr(os, name, function)
                        shutil.rmtree = rmtree
                    self.assertIn(self.pair(), {("OLD = True\n", "OLD = True\n"), ("VERSION = 2\n", "X = 1\n")})
                    self.assertFalse(self.host.restart_requested)
                    result = self.host.update_runner({"sha256": digest, "bytes": len(data)})
                    self.assertIn(result["state"], ("installed", "current"))
                    self.assertEqual(("VERSION = 2\n", "X = 1\n"), self.pair())
                    self.assertEqual(digest, runner.installed_runner_bundle(self.runner_dir))
                    self.assertEqual([], self.leftovers())

    def test_the_installed_layout_runs_through_its_links(self):
        # The real files, installed by update_runner and started the way
        # systemd starts them: the entry link's --self-check must load the
        # backup module of the same version.
        source_dir = os.path.join(HERE, "..", "..", "host-runner")
        files = {}
        for name in runner.RUNNER_BUNDLE_FILES:
            with open(os.path.join(source_dir, name), "rb") as handle:
                files[name] = handle.read()
        data, digest = bundle(files)
        self.served[digest] = data
        host = runner.ResidentHost(self.dir, docker=FakeDocker(), http=FakeHttp(), sleep=lambda s: None,
                                   fetch_runner_bundle=lambda d, w: (w(data), (True, ""))[1],
                                   runner_dir=self.runner_dir)
        self.assertEqual("installed", host.update_runner({"sha256": digest, "bytes": len(data)})["state"])
        self.assertTrue(runner._runner_self_check(self.runner_dir))

    def test_an_oversized_member_is_refused_not_truncated(self):
        # Mira's P2 (#615): a highly compressible member past the unpacked
        # limit used to be read as its first MAX+1 bytes and installed.
        padded = b"X = 1\n" + b"#" * (runner.RUNNER_SOURCE_MAX_BYTES + 10) + b"\n"
        data, digest = bundle({"souls_house_runner.py": b"VERSION = 2\n", "backup_proxy.py": padded})
        self.assertLess(len(data), runner.RUNNER_BUNDLE_MAX_BYTES)
        self.served[digest] = data
        with self.assertRaises(runner.BadCommand):
            self.host.update_runner({"sha256": digest, "bytes": len(data)})
        self.assert_untouched()

    def test_update_runner_is_in_the_vocabulary(self):
        self.assertIn("update_runner", runner.COMMAND_KINDS)


if __name__ == "__main__":
    unittest.main()
