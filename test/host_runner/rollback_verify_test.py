"""Real-restic check of the rollback restore's destination verification (#426 3C cp3).

RESTIC_TEST_BINARY must be the restic from the image pinned in
test/fixtures/files/rollback_restic_contract.json (CI extracts it by digest).
The invocation comes from that fixture, which rollback_restic_contract_test.rb
binds to RollbackRestore.args and RollbackHome::RESTIC_FLAGS, so this runs what
ships: the same binary, flags, snapshot path and --target /rollback/<role>.

/rollback must be writable (CI: sudo mkdir + chown). For a local run without
root, ROLLBACK_TEST_ROOT replaces the /rollback prefix; CI never sets it.

The negative control corrupts destination bytes *during* the restore: once
restic has written the first file, the test freezes restic (SIGSTOP), flips one
byte of that file, and lets it continue. Corruption in place before the restore
would prove nothing, because a valid restore may legitimately repair it.
"""
import json
import os
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BINARY = os.environ.get("RESTIC_TEST_BINARY")
ROOT = os.environ.get("ROLLBACK_TEST_ROOT", "/rollback")
ROLE = "chaos"
# Read only when the check runs: packaged_test.py copies this directory alone
# into a temporary tree, without the fixture.
CONTRACT = None
if BINARY:
    with open(os.path.join(HERE, "..", "fixtures", "files", "rollback_restic_contract.json")) as handle:
        CONTRACT = json.load(handle)


def local(path):
    """The production path, under ROLLBACK_TEST_ROOT when one is set."""
    assert path.startswith("/rollback/"), path
    return ROOT + path[len("/rollback"):]


@unittest.skipUnless(BINARY, "pinned restic executable not supplied")
class RollbackVerifyTest(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.mkdtemp()
        self.env = {"PATH": "/usr/bin:/bin", "HOME": self.work,
                    "RESTIC_PASSWORD": "synthetic-rollback-test-password",
                    "RESTIC_REPOSITORY": os.path.join(self.work, "repo")}
        self.target = local("/rollback/" + ROLE)
        self.assertFalse(os.path.exists(self.target), "the fresh target must not exist before the test")
        os.makedirs(self.target)
        # A small file restic writes early, and a large one that keeps the
        # restore busy long after it, so the freeze lands before verification.
        self.first = os.urandom(200_000)
        with open(os.path.join(self.target, "a-first"), "wb") as handle:
            handle.write(self.first)
        with open(os.path.join(self.target, "z-large"), "wb") as handle:
            for _ in range(64):
                handle.write(os.urandom(4 << 20))
        self.restic("init")
        self.restic("backup", "--host", "souls-house-rollback", "--tag", "rollback=v1", self.target)
        self.snapshot = json.loads(self.restic("snapshots", "--json").stdout)[0]["id"]
        shutil.rmtree(self.target)

    def tearDown(self):
        shutil.rmtree(self.target, ignore_errors=True)
        shutil.rmtree(self.work, ignore_errors=True)

    def restic(self, *args):
        return subprocess.run([BINARY, "--no-cache", *args], env=self.env, check=True, capture_output=True, text=True)

    def shipped_restore(self, verify=True):
        args = [arg.replace("{snapshot}", self.snapshot).replace("{role}", ROLE) for arg in CONTRACT["restore"]]
        if not verify:
            args.remove("--verify")
        if ROOT != "/rollback":
            # Only the --target value is rewritten; the snapshot path is the
            # backed-up one, which already lives under ROOT.
            args[args.index("--target") + 1] = self.target
            args[1] = f"{self.snapshot}:{self.target}"
        # The executor's flags, minus the REST-only connection option: this
        # repository is local, which changes nothing about the destination.
        flags = [flag for flag in CONTRACT["flags"]]
        index = flags.index("-o")
        del flags[index:index + 2]
        return [BINARY, *flags, *args]

    def run_with_corruption(self, argv):
        """Run argv; flip one byte of a-first once restic has written it."""
        process = subprocess.Popen(argv, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        path = os.path.join(self.target, "a-first")
        flipped = False
        deadline = time.monotonic() + 120
        while process.poll() is None and time.monotonic() < deadline:
            try:
                with open(path, "rb") as handle:
                    written = handle.read() == self.first
            except FileNotFoundError:
                written = False
            if written:
                os.kill(process.pid, signal.SIGSTOP)
                try:
                    with open(path, "r+b") as handle:
                        handle.seek(777)
                        byte = handle.read(1)
                        handle.seek(777)
                        handle.write(bytes([byte[0] ^ 0xFF]))
                    flipped = True
                finally:
                    os.kill(process.pid, signal.SIGCONT)
                break
            time.sleep(0.002)
        output = process.communicate(timeout=300)[0].decode(errors="replace")
        self.assertTrue(flipped, "restic finished before the first file could be corrupted:\n" + output)
        return process.returncode, output

    def test_shipped_invocation_carries_verify_and_no_overwrite_mode(self):
        argv = self.shipped_restore()
        self.assertIn("--verify", argv)
        self.assertIn("--no-lock", argv)
        self.assertFalse(any(arg.startswith("--overwrite") for arg in argv))

    def test_clean_restore_into_a_fresh_target_verifies(self):
        result = subprocess.run(self.shipped_restore(), env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("verifying files in", result.stdout)
        with open(os.path.join(self.target, "a-first"), "rb") as handle:
            self.assertEqual(handle.read(), self.first)

    def test_destination_bytes_changed_during_restore_fail_verification(self):
        returncode, output = self.run_with_corruption(self.shipped_restore())
        self.assertNotEqual(returncode, 0, output)
        self.assertIn("Unexpected content", output)
        self.assertIn("a-first", output)

    def test_control_without_verify_the_same_corruption_passes(self):
        # Shows --verify is what catches it: restic alone exits 0 on bad bytes.
        returncode, output = self.run_with_corruption(self.shipped_restore(verify=False))
        self.assertEqual(returncode, 0, output)
        with open(os.path.join(self.target, "a-first"), "rb") as handle:
            self.assertNotEqual(handle.read(), self.first)

    def test_preexisting_same_size_corruption_is_repaired_by_the_default_overwrite(self):
        os.makedirs(self.target)
        damaged = bytearray(self.first)
        damaged[777] ^= 0xFF
        with open(os.path.join(self.target, "a-first"), "wb") as handle:
            handle.write(damaged)
        result = subprocess.run(self.shipped_restore(), env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with open(os.path.join(self.target, "a-first"), "rb") as handle:
            self.assertEqual(handle.read(), self.first)


if __name__ == "__main__":
    unittest.main()
