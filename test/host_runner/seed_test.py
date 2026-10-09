import hashlib
import io
import os
import shutil
import sys
import tarfile
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "host-runner"))

import souls_house_runner as runner  # noqa: E402


def archive(entries):
    """entries: list of (name, bytes or None for a directory, extra tarinfo attrs)."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w:gz") as tar:
        for name, data, *extra in entries:
            info = tarfile.TarInfo(name)
            if data is None:
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tar.addfile(info)
            else:
                info.size = len(data)
                info.mode = 0o644
                for attrs in extra:
                    for key, value in attrs.items():
                        setattr(info, key, value)
                tar.addfile(info, io.BytesIO(data) if info.isfile() else None)
    return raw.getvalue()


HOME = archive([("soul.md", b"# soul\n"), ("memory", None), ("memory/.keep", b""),
                ("memory/daily-journals/README.md", b"readme\n")])


class VolumeDocker:
    """docker volume create/inspect against a real temp directory."""

    def __init__(self, mountpoint, fail=()):
        self.mountpoint = mountpoint
        self.calls = []
        self.fail = set(fail)

    def __call__(self, argv, timeout=120):
        self.calls.append(argv)
        verb = " ".join(argv[1:3])
        if verb in self.fail:
            return False, "boom"
        if verb == "volume create":
            os.makedirs(self.mountpoint, exist_ok=True)
            return True, argv[-1]
        if verb == "volume inspect":
            return True, self.mountpoint
        return False, f"unexpected {argv}"


class SeedHomeTest(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = os.path.join(self.tmp.name, "state")
        os.makedirs(self.state)
        self.volume = os.path.join(self.tmp.name, "volumes", "agent-1-identity")
        self.docker = VolumeDocker(self.volume)
        self.served = []

    def tearDown(self):
        self.tmp.cleanup()

    def host(self, data=HOME, ok=True):
        def fetch(digest, write):
            self.served.append(digest)
            if not ok:
                return False, "house answered 404"
            for start in range(0, len(data), 7):
                write(data[start:start + 7])
            return True, ""
        return runner.ResidentHost(self.state, docker=self.docker, fetch_seed=fetch)

    def payload(self, data=HOME, **overrides):
        base = {"container_name": "agent-1", "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
        base.update(overrides)
        return base

    def run_seed(self, host, payload, cid="b" * 32, generation=1, state=None):
        state = state or runner.CommandState(self.state)
        command = {"id": cid, "kind": "seed_home", "generation": generation, "payload": payload}
        return runner.execute_command(command, state, host)[1]

    def test_seeds_an_empty_volume_and_writes_the_marker_last(self):
        result = self.run_seed(self.host(), self.payload())
        self.assertEqual("done", result["outcome"], result)
        self.assertEqual({"state": "seeded", "sha256": self.payload()["sha256"], "already": False, "entries": 4},
                         result["result"])
        with open(os.path.join(self.volume, "soul.md")) as handle:
            self.assertEqual("# soul\n", handle.read())
        self.assertTrue(os.path.exists(os.path.join(self.volume, "memory", "daily-journals", "README.md")))
        with open(os.path.join(self.volume, runner.SEED_MARKER)) as handle:
            self.assertEqual(self.payload()["sha256"], handle.read().strip())
        self.assertFalse(os.path.exists(os.path.join(self.volume, runner.SEED_STAGING)))
        self.assertIn(["docker", "volume", "create", "agent-1-identity"], self.docker.calls)

    def test_a_new_command_with_the_same_digest_after_a_lost_answer_is_done_without_fetching(self):
        self.run_seed(self.host(), self.payload())
        self.served.clear()
        result = self.run_seed(self.host(), self.payload(), cid="c" * 32)
        self.assertEqual("done", result["outcome"], result)
        self.assertTrue(result["result"]["already"])
        self.assertEqual([], self.served)

    def test_a_different_digest_is_refused_and_the_home_is_untouched(self):
        self.run_seed(self.host(), self.payload())
        other = archive([("soul.md", b"# someone else\n")])
        result = self.run_seed(self.host(other), self.payload(other), cid="c" * 32)
        self.assertEqual("refused", result["outcome"])
        self.assertIn("different archive", result["error"])
        with open(os.path.join(self.volume, "soul.md")) as handle:
            self.assertEqual("# soul\n", handle.read())

    def test_a_volume_with_anything_in_it_and_no_marker_is_refused_and_left_alone(self):
        os.makedirs(self.volume)
        with open(os.path.join(self.volume, "journal.md"), "w") as handle:
            handle.write("mine")
        result = self.run_seed(self.host(), self.payload())
        self.assertEqual("refused", result["outcome"])
        self.assertEqual(["journal.md"], os.listdir(self.volume))
        self.assertEqual([], self.served)

    def test_a_staging_directory_left_by_an_interrupted_run_is_refused(self):
        os.makedirs(os.path.join(self.volume, runner.SEED_STAGING))
        result = self.run_seed(self.host(), self.payload())
        self.assertEqual("refused", result["outcome"])
        self.assertTrue(os.path.isdir(os.path.join(self.volume, runner.SEED_STAGING)))

    def test_bytes_that_do_not_match_the_digest_fail_and_write_nothing(self):
        payload = self.payload(sha256="0" * 64)
        result = self.run_seed(self.host(), payload)
        self.assertEqual("failed", result["outcome"])
        self.assertIn("digest", result["error"])
        self.assertEqual([], os.listdir(self.volume))

    def test_more_bytes_than_announced_fail_before_unpacking(self):
        result = self.run_seed(self.host(), self.payload(bytes=10))
        self.assertEqual("failed", result["outcome"])
        self.assertEqual([], os.listdir(self.volume))

    def test_a_failed_fetch_leaves_the_volume_empty_so_a_retry_can_seed(self):
        result = self.run_seed(self.host(ok=False), self.payload())
        self.assertEqual("failed", result["outcome"])
        self.assertEqual([], os.listdir(self.volume))
        retry = self.run_seed(self.host(), self.payload(), cid="c" * 32)
        self.assertEqual("done", retry["outcome"], retry)

    def test_unsafe_entries_are_refused_before_anything_is_written(self):
        cases = [
            archive([("../escape.md", b"x")]),
            archive([("/etc/passwd", b"x")]),
            archive([("ok.md", b"x"), ("a/../../b", b"x")]),
            archive([("link", b"", {"type": tarfile.SYMTYPE, "linkname": "/etc/passwd", "size": 0})]),
            archive([("hard", b"", {"type": tarfile.LNKTYPE, "linkname": "soul.md", "size": 0})]),
            archive([("fifo", b"", {"type": tarfile.FIFOTYPE, "size": 0})]),
        ]
        for index, data in enumerate(cases):
            with self.subTest(index=index):
                result = self.run_seed(self.host(data), self.payload(data), cid=f"{index:032x}")
                self.assertEqual("refused", result["outcome"], result)
                self.assertEqual([], os.listdir(self.volume))

    def test_not_a_gzipped_tar_fails(self):
        data = b"not an archive"
        result = self.run_seed(self.host(data), self.payload(data))
        self.assertEqual("failed", result["outcome"])
        self.assertEqual([], os.listdir(self.volume))

    def test_bad_payloads_are_refused(self):
        for bad in ({"container_name": "../x"}, {"sha256": "abc"}, {"bytes": 0},
                    {"bytes": runner.SEED_MAX_BYTES + 1}, {"bytes": True}):
            with self.subTest(bad=bad):
                result = self.run_seed(self.host(), self.payload(**bad), cid=hashlib.md5(repr(bad).encode()).hexdigest())
                self.assertEqual("refused", result["outcome"])

    def test_entry_count_and_unpacked_size_are_capped(self):
        original = (runner.SEED_MAX_ENTRIES, runner.SEED_MAX_UNPACKED)
        try:
            runner.SEED_MAX_ENTRIES = 2
            result = self.run_seed(self.host(), self.payload())
            self.assertEqual("refused", result["outcome"])
            runner.SEED_MAX_ENTRIES = original[0]
            runner.SEED_MAX_UNPACKED = 3
            result = self.run_seed(self.host(), self.payload(), cid="c" * 32)
            self.assertEqual("refused", result["outcome"])
            self.assertEqual([], os.listdir(self.volume))
        finally:
            runner.SEED_MAX_ENTRIES, runner.SEED_MAX_UNPACKED = original

    def test_the_scan_stops_at_the_entry_cap_instead_of_parsing_everything(self):
        many = archive([(f"f{i}.md", b"x") for i in range(50)])
        calls = []
        original_next = tarfile.TarFile.next

        def counting_next(tar):
            calls.append(1)
            return original_next(tar)

        original_cap = runner.SEED_MAX_ENTRIES
        try:
            runner.SEED_MAX_ENTRIES = 2
            tarfile.TarFile.next = counting_next
            result = self.run_seed(self.host(many), self.payload(many))
        finally:
            tarfile.TarFile.next = original_next
            runner.SEED_MAX_ENTRIES = original_cap
        self.assertEqual("refused", result["outcome"])
        self.assertLessEqual(len(calls), 4, "the scan must stop at the cap")
        self.assertEqual([], os.listdir(self.volume))

    def test_a_marker_that_is_not_a_small_regular_file_is_refused_and_nothing_is_fetched(self):
        digest = self.payload()["sha256"]
        elsewhere = os.path.join(self.tmp.name, "forged")
        with open(elsewhere, "w") as handle:
            handle.write(digest)
        cases = {
            "symlink": lambda marker: os.symlink(elsewhere, marker),
            "fifo": lambda marker: os.mkfifo(marker),
            "directory": lambda marker: os.mkdir(marker),
            "oversized": lambda marker: open(marker, "w").write(digest + " " * 200),
        }
        for index, (name, make) in enumerate(cases.items()):
            with self.subTest(marker=name):
                shutil.rmtree(self.volume, ignore_errors=True)
                os.makedirs(self.volume)
                make(os.path.join(self.volume, runner.SEED_MARKER))
                result = self.run_seed(self.host(), self.payload(), cid=f"{index + 10:032x}")
                self.assertEqual("refused", result["outcome"], result)
                self.assertEqual([runner.SEED_MARKER], os.listdir(self.volume))
                self.assertEqual([], self.served)

    def test_seed_home_is_in_the_runner_vocabulary(self):
        self.assertIn("seed_home", runner.COMMAND_KINDS)


class FetchSeedTest(unittest.TestCase):

    class Response:
        def __init__(self, status, body):
            self.status = status
            self.body = io.BytesIO(body)

        def read(self, size):
            return self.body.read(size)

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

    def setUp(self):
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        self.key = Ed25519PrivateKey.generate()
        self.config = {"rails_url": "https://house.example", "runner_id": "rnr_" + "a" * 20}

    def test_signed_get_of_the_digest_path(self):
        seen = []

        def opener(request, timeout):
            seen.append(request)
            return self.Response(200, b"abc")

        chunks = []
        ok, error = runner.fetch_seed(self.config, self.key, "f" * 64, chunks.append, opener=opener)
        self.assertTrue(ok, error)
        self.assertEqual(b"abc", b"".join(chunks))
        self.assertEqual("https://house.example/api/v1/host_runner/seeds/" + "f" * 64, seen[0].full_url)
        self.assertEqual("GET", seen[0].get_method())
        self.assertIn("X-runner-signature", seen[0].headers)

    def test_a_non_200_is_a_failure(self):
        ok, error = runner.fetch_seed(self.config, self.key, "f" * 64, lambda c: None,
                                      opener=lambda request, timeout: self.Response(302, b""))
        self.assertFalse(ok)
        self.assertIn("302", error)

    def test_a_bad_digest_never_reaches_the_network(self):
        def opener(request, timeout):
            raise AssertionError("should not fetch")
        self.assertEqual((False, "bad seed digest"), runner.fetch_seed(self.config, self.key, "../x", None, opener=opener))


if __name__ == "__main__":
    unittest.main()
