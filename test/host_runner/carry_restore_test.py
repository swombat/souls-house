import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "host-runner"))

import carry_restore as cr  # noqa: E402
import souls_house_runner as runner  # noqa: E402
from backup_proxy import CLEANUP_SECONDS, MAX_DEADLINE_SECONDS  # noqa: E402
from souls_house_runner import CommandFailed  # noqa: E402


# ---------------------------------------------------------------------------
# Shared payload/shape builders
# ---------------------------------------------------------------------------

def valid_shapes():
    return {
        "chaos": {"entries": 2, "shape": "1" * 64},
        "state": {"entries": 5, "shape": "2" * 64},
    }


def valid_payload(container_name="agent-carry", snapshot_id=None, shapes=None, deadline_seconds=300):
    return {
        "container_name": container_name,
        "agent_uuid": "12345678-1234-1234-1234-123456789012",
        "restic_password": "s3cr3t",
        "snapshot_id": snapshot_id or ("f" * 64),
        "deadline_seconds": deadline_seconds,
        "shapes": shapes if shapes is not None else valid_shapes(),
    }


def shape_output(shape):
    """Exactly what carry_shape.sh prints for a given {"entries", "shape"}."""
    return f"entries {shape['entries']}\nshape {shape['shape']}\n"


# ---------------------------------------------------------------------------
# Fakes: no real docker, network, or restic ever runs.
# ---------------------------------------------------------------------------

class FakeHost:
    """Stands in for the runner's ResidentHost: state_dir, backup_request,
    current_command_id, _write_private, docker (volume ops only) and
    _volume_mountpoint, each backed by a real temp directory so markers and
    volume emptiness are genuinely exercised, never mocked away."""

    def __init__(self, root):
        self.state_dir = os.path.join(root, "state")
        os.makedirs(self.state_dir, exist_ok=True)
        self.volumes_root = os.path.join(root, "volumes")
        os.makedirs(self.volumes_root, exist_ok=True)
        self.backup_request = "fake-signed-request"
        self.current_command_id = "a" * 32
        self.docker_calls = []
        self.docker_timeouts = []
        self.existing = set()
        self.removed = []

    def _write_private(self, path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)

    def _volume_mountpoint(self, volume):
        path = os.path.join(self.volumes_root, volume)
        os.makedirs(path, exist_ok=True)
        return path

    def seed_volume(self, volume, files=()):
        """Test helper: register a volume as already created (as a seed step
        would, before any carry restore runs), optionally with leftover
        content so a non-empty or partially-restored volume can be tested."""
        path = self._volume_mountpoint(volume)
        self.existing.add(volume)
        for name in files:
            with open(os.path.join(path, name), "w", encoding="utf-8") as handle:
                handle.write("leftover")

    def docker(self, argv, timeout=None):
        self.docker_calls.append(list(argv))
        self.docker_timeouts.append(timeout)
        if argv[:3] == ["docker", "volume", "create"]:
            self.existing.add(argv[3])
            self._volume_mountpoint(argv[3])
            return True, ""
        if argv[:5] == ["docker", "volume", "inspect", "--format", "{{.Mountpoint}}"]:
            return True, self._volume_mountpoint(argv[5])
        if argv[:3] == ["docker", "volume", "inspect"]:
            name = argv[3]
            return (name in self.existing), ("" if name in self.existing else "no such volume")
        if argv[:3] == ["docker", "volume", "rm"]:
            name = argv[3]
            if name in self.existing:
                self.existing.discard(name)
                self.removed.append(name)
                path = self._volume_mountpoint(name)
                for entry in os.listdir(path):
                    full = os.path.join(path, entry)
                    if os.path.isdir(full):
                        shutil.rmtree(full)
                    else:
                        os.unlink(full)
            return True, ""
        raise AssertionError(f"unexpected host.docker call: {argv}")


class FakeDocker:
    """Stands in for run_restore_carry's injected docker(argv, timeout=...).
    Recognises exactly the calls carry_restore.py makes and nothing else, so
    an unexpected call (a real docker invocation sneaking in) fails loudly."""

    def __init__(self):
        self.calls = []
        self.container_exists = False
        self.image_present = True
        self.restore_ok = True
        self.rm_ok = True
        self.ps_tools = ()
        self.shape_outputs = {}
        self.on_restore = None

    def __call__(self, argv, timeout=None):
        self.calls.append(list(argv))
        if argv[:3] == ["docker", "container", "inspect"]:
            return self.container_exists, ""
        if argv[:3] == ["docker", "image", "inspect"]:
            return self.image_present, ""
        if argv[:2] == ["docker", "pull"]:
            return True, ""
        if argv[0] == "docker" and argv[1] == "run":
            mode = argv[argv.index("--network") + 1]
            if mode == "host":
                if self.on_restore:
                    self.on_restore()
                return self.restore_ok, ""
            role = self._role_of(argv)
            return True, self.shape_outputs.get(role, "")
        if argv[:3] == ["docker", "rm", "-f"]:
            return self.rm_ok, ""
        if argv[:2] == ["docker", "ps"]:
            return True, "\n".join(self.ps_tools)
        raise AssertionError(f"unexpected docker call: {argv}")

    @staticmethod
    def _role_of(argv):
        for part in argv:
            if part.startswith("type=volume,src="):
                src = part.split("src=", 1)[1].split(",", 1)[0]
                for role in cr.CARRY_ROLES:
                    if src.endswith("-" + role):
                        return role
        return None


class FakeProxy:
    """Stands in for BackupProxy: no loopback HTTP server, no thread."""

    def __init__(self, signed_request, deadline):
        self.signed_request = signed_request
        self.deadline = deadline
        self.repository = "rest:http://fake-proxy.invalid/"

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


# ---------------------------------------------------------------------------
# run_restore_carry
# ---------------------------------------------------------------------------

class CarryRestoreTestCase(unittest.TestCase):
    """Base fixture: a resident whose two carry volumes already exist (as a
    prior seed step would have made them) and are empty."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.host = FakeHost(self.tmp.name)
        self.docker = FakeDocker()
        self.name = "agent-carry"
        self.chaos_volume = f"{self.name}-chaos"
        self.state_volume = f"{self.name}-state"
        self.host.seed_volume(self.chaos_volume)
        self.host.seed_volume(self.state_volume)

    def payload(self, **overrides):
        base = valid_payload(self.name)
        base.update(overrides)
        return base

    def run_restore(self, payload=None, **kwargs):
        payload = self.payload() if payload is None else payload
        kwargs.setdefault("docker", self.docker)
        kwargs.setdefault("proxy_factory", FakeProxy)
        kwargs.setdefault("script", "# fake carry_shape.sh, never executed\n")
        kwargs.setdefault("clock", lambda: 1_000.0)
        return cr.run_restore_carry(payload, self.host, **kwargs)


class RunRestoreCarrySuccessTest(CarryRestoreTestCase):
    def test_valid_payload_with_matching_shapes_succeeds_and_marks_verified(self):
        shapes = valid_shapes()
        self.docker.shape_outputs = {role: shape_output(shapes[role]) for role in cr.CARRY_ROLES}
        result = self.run_restore(self.payload(shapes=shapes))
        self.assertFalse(result["already"])
        self.assertTrue(result["tools_stopped"])
        self.assertEqual(shapes, result["shapes"])
        marker = cr.read_marker(self.host, self.name)
        self.assertEqual("verified", marker["state"])
        self.assertEqual(shapes, marker["shapes"])
        self.assertEqual(("f" * 64), marker["snapshot_id"])


class RunRestoreCarryRetryAndMarkerTest(CarryRestoreTestCase):
    def test_retry_with_a_verified_marker_for_the_same_snapshot_is_already_done(self):
        shapes = valid_shapes()
        snapshot_id = "f" * 64
        cr.write_marker(self.host, self.name, {"state": "verified", "snapshot_id": snapshot_id, "shapes": shapes})
        result = self.run_restore(self.payload(snapshot_id=snapshot_id, shapes=shapes))
        self.assertTrue(result["already"])
        self.assertEqual(shapes, result["shapes"])
        self.assertEqual([], self.docker.calls, "an already-verified retry must never touch docker")
        self.assertEqual([], self.host.docker_calls, "an already-verified retry must never touch a volume")

    def test_claimed_marker_for_the_same_carry_clears_volumes_and_restores_again(self):
        shapes = valid_shapes()
        snapshot_id = "f" * 64
        cr.write_marker(self.host, self.name, {"state": "claimed", "snapshot_id": snapshot_id, "shapes": shapes})
        # The leftover bytes of an interrupted previous attempt.
        for volume in (self.chaos_volume, self.state_volume):
            with open(os.path.join(self.host._volume_mountpoint(volume), "partial"), "w") as handle:
                handle.write("partial restore")
        self.docker.shape_outputs = {role: shape_output(shapes[role]) for role in cr.CARRY_ROLES}
        result = self.run_restore(self.payload(snapshot_id=snapshot_id, shapes=shapes))
        self.assertFalse(result["already"])
        self.assertEqual({self.chaos_volume, self.state_volume}, set(self.host.removed))
        marker = cr.read_marker(self.host, self.name)
        self.assertEqual("verified", marker["state"])

    def test_a_marker_for_a_different_snapshot_is_refused_and_left_untouched(self):
        other_snapshot = "0" * 64
        cr.write_marker(self.host, self.name,
                         {"state": "claimed", "snapshot_id": other_snapshot, "shapes": valid_shapes()})
        with self.assertRaises(runner.BadCommand):
            self.run_restore()
        self.assertEqual([], self.docker.calls)
        self.assertEqual([], self.host.removed)
        marker = cr.read_marker(self.host, self.name)
        self.assertEqual(other_snapshot, marker["snapshot_id"])


class RunRestoreCarryVolumeSafetyTest(CarryRestoreTestCase):
    def test_a_nonempty_target_volume_is_refused_and_never_removed(self):
        self.host.seed_volume(self.state_volume, files=["leftover.txt"])
        with self.assertRaises(runner.BadCommand):
            self.run_restore()
        self.assertIn(self.state_volume, self.host.existing)
        self.assertEqual([], self.host.removed)
        self.assertEqual(["leftover.txt"], os.listdir(self.host._volume_mountpoint(self.state_volume)))
        self.assertIsNone(cr.read_marker(self.host, self.name))
        # Refused before any restic restore was ever attempted.
        self.assertEqual([["docker", "container", "inspect", self.name]], self.docker.calls)

    def test_a_shape_mismatch_fails_removes_the_claimed_volumes_and_clears_the_marker(self):
        shapes = valid_shapes()
        outputs = {role: shape_output(shapes[role]) for role in cr.CARRY_ROLES}
        # The restored "state" home measures differently from what the house recorded.
        outputs["state"] = shape_output({"entries": shapes["state"]["entries"], "shape": "9" * 64})
        self.docker.shape_outputs = outputs
        with self.assertRaises(cr.CarryFailed) as caught:
            self.run_restore(self.payload(shapes=shapes))
        self.assertIn("state", str(caught.exception))
        failed_result = caught.exception.result
        self.assertTrue(failed_result["tools_stopped"])
        self.assertEqual(shapes["chaos"], failed_result["shapes"]["chaos"])
        self.assertEqual({self.chaos_volume, self.state_volume}, set(self.host.removed))
        self.assertNotIn(self.chaos_volume, self.host.existing)
        self.assertNotIn(self.state_volume, self.host.existing)
        self.assertIsNone(cr.read_marker(self.host, self.name))


class RunRestoreCarryTransportTest(CarryRestoreTestCase):
    def test_missing_backup_request_is_refused_before_any_docker_call(self):
        self.host.backup_request = None
        with self.assertRaises(runner.BadCommand) as caught:
            self.run_restore()
        self.assertEqual("backup transport unavailable", str(caught.exception))
        self.assertEqual([], self.docker.calls)
        self.assertEqual([], self.host.docker_calls)

    def test_a_bad_current_command_id_is_refused(self):
        for bad in ("not-hex", "a" * 31, "A" * 32, "", None):
            with self.subTest(bad=bad):
                self.host.current_command_id = bad
                with self.assertRaises(runner.BadCommand):
                    self.run_restore()


# ---------------------------------------------------------------------------
# validate_carry
# ---------------------------------------------------------------------------

class ValidateCarryTest(unittest.TestCase):
    def payload(self, **overrides):
        base = valid_payload()
        base.update(overrides)
        return base

    def test_accepts_a_well_formed_payload(self):
        payload = self.payload()
        validated = cr.validate_carry(payload)
        self.assertEqual(payload, validated)
        self.assertIsNot(payload, validated)

    def test_rejects_a_missing_key(self):
        payload = self.payload()
        del payload["deadline_seconds"]
        with self.assertRaises(runner.BadCommand):
            cr.validate_carry(payload)

    def test_rejects_an_extra_key(self):
        with self.assertRaises(runner.BadCommand):
            cr.validate_carry(self.payload(unexpected="nope"))

    def test_rejects_a_bad_snapshot_id(self):
        for bad in ("F" * 64, "g" * 64, "a" * 63, "a" * 65, 12345, None, ""):
            with self.subTest(bad=bad):
                with self.assertRaises(runner.BadCommand):
                    cr.validate_carry(self.payload(snapshot_id=bad))

    def test_rejects_a_bad_shape_digest(self):
        bad_shapes = [
            {"entries": 1, "shape": "A" * 64},      # uppercase hex
            {"entries": 1, "shape": "a" * 63},       # too short
            {"entries": -1, "shape": "a" * 64},      # negative entries
            {"entries": 1.0, "shape": "a" * 64},     # not an int
            {"entries": True, "shape": "a" * 64},    # bool is not int
            {"shape": "a" * 64},                     # missing entries
        ]
        for bad_shape in bad_shapes:
            with self.subTest(bad_shape=bad_shape):
                shapes = valid_shapes()
                shapes["chaos"] = bad_shape
                with self.assertRaises(runner.BadCommand):
                    cr.validate_carry(self.payload(shapes=shapes))

    def test_rejects_a_non_int_deadline(self):
        for bad in (300.0, "300", True, None):
            with self.subTest(bad=bad):
                with self.assertRaises(runner.BadCommand):
                    cr.validate_carry(self.payload(deadline_seconds=bad))

    def test_rejects_a_deadline_outside_the_allowed_window(self):
        for bad in (CLEANUP_SECONDS, MAX_DEADLINE_SECONDS + 1, 0, -5):
            with self.subTest(bad=bad):
                with self.assertRaises(runner.BadCommand):
                    cr.validate_carry(self.payload(deadline_seconds=bad))


# ---------------------------------------------------------------------------
# parse_shape
# ---------------------------------------------------------------------------

class ParseShapeTest(unittest.TestCase):
    def test_accepts_the_two_expected_lines(self):
        parsed = cr.parse_shape("entries 3\nshape " + "a" * 64 + "\n")
        self.assertEqual({"entries": 3, "shape": "a" * 64}, parsed)

    def test_accepts_zero_entries(self):
        parsed = cr.parse_shape("entries 0\nshape " + "b" * 64 + "\n")
        self.assertEqual(0, parsed["entries"])

    def test_rejects_an_extra_line(self):
        with self.assertRaises(runner.CommandFailed):
            cr.parse_shape("entries 3\nshape " + "a" * 64 + "\nextra\n")

    def test_rejects_uppercase_hex(self):
        with self.assertRaises(runner.CommandFailed):
            cr.parse_shape("entries 3\nshape " + "A" * 64 + "\n")

    def test_rejects_a_missing_entries_line(self):
        with self.assertRaises(runner.CommandFailed):
            cr.parse_shape("shape " + "a" * 64 + "\n")

    def test_rejects_a_leading_zero_entry_count(self):
        with self.assertRaises(runner.CommandFailed):
            cr.parse_shape("entries 01\nshape " + "a" * 64 + "\n")

    def test_rejects_empty_output(self):
        with self.assertRaises(runner.CommandFailed):
            cr.parse_shape("")


# ---------------------------------------------------------------------------
# read_marker / write_marker / clear_marker / volume_exists / volume_is_empty
# / remove_volume, exercised directly against the fake host.
# ---------------------------------------------------------------------------

class MarkerAndVolumeHelperTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.host = FakeHost(self.tmp.name)
        self.name = "agent-carry"

    def test_read_marker_missing_is_none(self):
        self.assertIsNone(cr.read_marker(self.host, self.name))

    def test_write_then_read_marker_roundtrips(self):
        data = {"state": "claimed", "snapshot_id": "a" * 64, "shapes": valid_shapes()}
        cr.write_marker(self.host, self.name, data)
        self.assertEqual(data, cr.read_marker(self.host, self.name))

    def test_clear_marker_on_a_missing_marker_is_a_no_op(self):
        cr.clear_marker(self.host, self.name)  # must not raise
        self.assertIsNone(cr.read_marker(self.host, self.name))

    def test_clear_marker_removes_an_existing_marker(self):
        cr.write_marker(self.host, self.name, {"state": "claimed"})
        cr.clear_marker(self.host, self.name)
        self.assertIsNone(cr.read_marker(self.host, self.name))

    def test_volume_exists_reflects_host_docker_volume_inspect(self):
        volume = f"{self.name}-chaos"
        self.assertFalse(cr.volume_exists(self.host, volume))
        self.host.seed_volume(volume)
        self.assertTrue(cr.volume_exists(self.host, volume))

    def test_volume_is_empty_checks_the_mountpoint_listing(self):
        volume = f"{self.name}-state"
        self.host.seed_volume(volume)
        self.assertTrue(cr.volume_is_empty(self.host, volume))
        with open(os.path.join(self.host._volume_mountpoint(volume), "x"), "w") as handle:
            handle.write("x")
        self.assertFalse(cr.volume_is_empty(self.host, volume))

    def test_remove_volume_is_a_noop_when_the_volume_does_not_exist(self):
        volume = f"{self.name}-chaos"
        self.assertTrue(cr.remove_volume(self.host, volume))
        self.assertEqual([["docker", "volume", "inspect", volume]], self.host.docker_calls)

    def test_remove_volume_removes_an_existing_volume(self):
        volume = f"{self.name}-state"
        self.host.seed_volume(volume)
        self.assertTrue(cr.remove_volume(self.host, volume))
        self.assertNotIn(volume, self.host.existing)
        self.assertIn(volume, self.host.removed)


if __name__ == "__main__":
    unittest.main()


# ---------------------------------------------------------------------------
# check_sessions: real files and a real sqlite database, nothing faked.
# ---------------------------------------------------------------------------

class CheckSessionsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name

    def home(self, *processes, sub="", wal=False):
        base = os.path.join(self.root, sub) if sub else self.root
        os.makedirs(base, exist_ok=True)
        import sqlite3 as sql
        connection = sql.connect(os.path.join(base, "chaos.sqlite"))
        if wal:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("PRAGMA wal_autocheckpoint=0")
        connection.execute("CREATE TABLE IF NOT EXISTS processes (id TEXT PRIMARY KEY NOT NULL)")
        connection.executemany("INSERT INTO processes (id) VALUES (?)", [(p,) for p in processes])
        connection.commit()
        return base, connection

    def map(self, base, **records):
        sessions = os.path.join(base, "helixkit-sessions")
        os.makedirs(sessions, exist_ok=True)
        for name, process_id in records.items():
            with open(os.path.join(sessions, f"{name}.json"), "w", encoding="utf-8") as handle:
                json.dump({"chaos_process_id": process_id, "session_id": name}, handle)

    def test_no_map_is_nothing_to_resolve(self):
        self.assertEqual({"mapped": 0, "resolved": 0}, cr.check_sessions(self.root))

    def test_every_mapped_session_resolves_in_both_homes(self):
        base, connection = self.home("p1", "p2")
        connection.close()
        self.map(base, a="p1", b="p2", fresh=None)
        oauth, connection = self.home("q1", sub="oauth-runtime")
        connection.close()
        self.map(oauth, c="q1")
        self.assertEqual({"mapped": 3, "resolved": 3}, cr.check_sessions(self.root))

    def test_an_unresolved_session_fails(self):
        base, connection = self.home("p1")
        connection.close()
        self.map(base, a="p1", b="gone")
        with self.assertRaisesRegex(CommandFailed, "does not resolve"):
            cr.check_sessions(self.root)

    def test_a_process_only_in_the_wal_resolves_and_the_volume_is_untouched(self):
        base, connection = self.home("p1", wal=True)  # left open: p1 lives only in the -wal
        self.addCleanup(connection.close)
        self.assertTrue(os.path.exists(os.path.join(base, "chaos.sqlite-wal")))
        self.map(base, a="p1")
        before = sorted(os.listdir(base))
        self.assertEqual({"mapped": 1, "resolved": 1}, cr.check_sessions(self.root))
        self.assertEqual(before, sorted(os.listdir(base)), "the check reads a copy and adds nothing to the volume")

    def test_a_map_without_a_database_fails(self):
        self.map(self.root, a="p1")
        with self.assertRaisesRegex(CommandFailed, "no Chaos database"):
            cr.check_sessions(self.root)

    def test_unreadable_or_odd_entries_fail(self):
        base, connection = self.home("p1")
        connection.close()
        self.map(base, a="p1")
        sessions = os.path.join(base, "helixkit-sessions")
        with open(os.path.join(sessions, "bad.json"), "w", encoding="utf-8") as handle:
            handle.write("{not json")
        with self.assertRaisesRegex(CommandFailed, "can't be read"):
            cr.check_sessions(self.root)
        os.unlink(os.path.join(sessions, "bad.json"))
        os.symlink("/etc/passwd", os.path.join(sessions, "link.json"))
        with self.assertRaisesRegex(CommandFailed, "can't be read"):
            cr.check_sessions(self.root)

    def test_a_symlinked_map_directory_fails(self):
        target = os.path.join(self.root, "elsewhere")
        os.makedirs(target)
        os.symlink(target, os.path.join(self.root, "helixkit-sessions"))
        with self.assertRaisesRegex(CommandFailed, "not a directory"):
            cr.check_sessions(self.root)

    def test_a_symlinked_oauth_home_outside_the_volume_fails(self):
        # Mira's catch on #788: oauth-runtime as a link to a map and database
        # outside the restored volume must not be accepted as resolved.
        outside = tempfile.mkdtemp(prefix="carry-outside-")
        self.addCleanup(shutil.rmtree, outside, True)
        import sqlite3 as sql
        connection = sql.connect(os.path.join(outside, "chaos.sqlite"))
        connection.execute("CREATE TABLE processes (id TEXT PRIMARY KEY NOT NULL)")
        connection.execute("INSERT INTO processes (id) VALUES ('q1')")
        connection.commit()
        connection.close()
        self.map(outside, c="q1")
        os.symlink(outside, os.path.join(self.root, "oauth-runtime"))
        with self.assertRaisesRegex(CommandFailed, "Chaos home is not a directory"):
            cr.check_sessions(self.root)


class RunRestoreCarrySessionTest(CarryRestoreTestCase):
    def test_an_unresolved_session_after_restore_fails_and_clears_the_claimed_volumes(self):
        shapes = valid_shapes()
        self.docker.shape_outputs = {role: shape_output(shapes[role]) for role in cr.CARRY_ROLES}
        chaos = self.host._volume_mountpoint(self.chaos_volume)

        def restored():  # what the restic restore would have written
            os.makedirs(os.path.join(chaos, "helixkit-sessions"))
            with open(os.path.join(chaos, "helixkit-sessions", "a.json"), "w", encoding="utf-8") as handle:
                json.dump({"chaos_process_id": "missing"}, handle)
            import sqlite3 as sql
            connection = sql.connect(os.path.join(chaos, "chaos.sqlite"))
            connection.execute("CREATE TABLE processes (id TEXT PRIMARY KEY NOT NULL)")
            connection.commit()
            connection.close()
        self.docker.on_restore = restored
        with self.assertRaises(cr.CarryFailed) as caught:
            self.run_restore(self.payload(shapes=shapes))
        self.assertIn("does not resolve", str(caught.exception))
        self.assertIsNone(cr.read_marker(self.host, self.name))
        self.assertIn(self.chaos_volume, self.host.removed)

    def test_a_verified_restore_reports_its_session_counts(self):
        shapes = valid_shapes()
        self.docker.shape_outputs = {role: shape_output(shapes[role]) for role in cr.CARRY_ROLES}
        result = self.run_restore(self.payload(shapes=shapes))
        self.assertEqual({"mapped": 0, "resolved": 0}, result["sessions"])
        self.assertEqual(result["sessions"], cr.read_marker(self.host, self.name)["sessions"])


    def test_a_session_check_that_finishes_late_is_not_certified(self):
        # Mira's reproduction on #788: a 60 s request whose session check
        # ran for 1000 s returned success and wrote "verified".
        shapes = valid_shapes()
        self.docker.shape_outputs = {role: shape_output(shapes[role]) for role in cr.CARRY_ROLES}
        now = [1_000.0]
        real = cr.check_sessions

        def slow(root, deadline=None, clock=None):
            counts = real(root)
            now[0] += 1_000.0
            return counts

        cr.check_sessions = slow
        self.addCleanup(setattr, cr, "check_sessions", real)
        with self.assertRaises(cr.CarryFailed) as caught:
            self.run_restore(self.payload(shapes=shapes, deadline_seconds=60), clock=lambda: now[0])
        self.assertIn("deadline", str(caught.exception))
        marker = cr.read_marker(self.host, self.name)
        self.assertNotEqual("verified", (marker or {}).get("state"))

    def test_volume_calls_carry_a_timeout(self):
        shapes = valid_shapes()
        outputs = {role: shape_output(shapes[role]) for role in cr.CARRY_ROLES}
        outputs["state"] = shape_output({"entries": shapes["state"]["entries"], "shape": "9" * 64})
        self.docker.shape_outputs = outputs
        with self.assertRaises(cr.CarryFailed):
            self.run_restore(self.payload(shapes=shapes))  # the failure path removes the claimed volumes
        self.assertTrue(self.host.docker_timeouts)
        self.assertNotIn(None, self.host.docker_timeouts)


    def test_mountpoint_calls_are_bounded_by_the_restore_clock(self):
        # Mira #788 round 2: the mountpoint lookup's two docker calls must not
        # fall back to the runner's 120 s default.
        shapes = valid_shapes()
        self.docker.shape_outputs = {role: shape_output(shapes[role]) for role in cr.CARRY_ROLES}
        try:
            self.run_restore(self.payload(shapes=shapes, deadline_seconds=cr.CLEANUP_SECONDS + 7))  # 7 s of work
        except cr.CarryFailed:
            pass
        lookups = [timeout for argv, timeout in zip(self.host.docker_calls, self.host.docker_timeouts)
                   if argv[:3] == ["docker", "volume", "create"] or argv[3:5] == ["--format", "{{.Mountpoint}}"]]
        self.assertGreaterEqual(len(lookups), 6)  # create + inspect for both roles, then chaos for the session check
        self.assertNotIn(None, lookups)
        self.assertTrue(all(timeout <= 7 for timeout in lookups), lookups)


class CheckSessionsDeadlineTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="carry-sessions-deadline-")
        self.addCleanup(shutil.rmtree, self.root, True)
        import sqlite3 as sql
        connection = sql.connect(os.path.join(self.root, "chaos.sqlite"))
        connection.execute("CREATE TABLE processes (id TEXT PRIMARY KEY NOT NULL)")
        connection.execute("INSERT INTO processes (id) VALUES ('p1')")
        connection.commit()
        connection.close()
        sessions = os.path.join(self.root, "helixkit-sessions")
        os.makedirs(sessions)
        with open(os.path.join(sessions, "a.json"), "w", encoding="utf-8") as handle:
            json.dump({"chaos_process_id": "p1"}, handle)

    def test_within_its_deadline_it_resolves(self):
        self.assertEqual({"mapped": 1, "resolved": 1}, cr.check_sessions(self.root, deadline=10.0, clock=lambda: 0.0))

    def test_past_its_deadline_it_stops(self):
        with self.assertRaisesRegex(CommandFailed, "deadline"):
            cr.check_sessions(self.root, deadline=10.0, clock=lambda: 11.0)

    def test_a_deadline_passing_during_the_copy_stops_it(self):
        ticks = iter([0.0, 0.0] + [11.0] * 100)
        with self.assertRaisesRegex(CommandFailed, "deadline"):
            cr.check_sessions(self.root, deadline=10.0, clock=lambda: next(ticks))


class CarryShapeScriptTest(unittest.TestCase):
    """Runs carry_shape.sh itself under dash (the CI shell closest to the
    pinned image's busybox ash). The pinned-image run is recorded on the PR."""

    SCRIPT = os.path.join(HERE, "..", "..", "host-runner", "carry_shape.sh")

    def setUp(self):
        self.tree = tempfile.mkdtemp(prefix="carry-shape-")
        self.addCleanup(shutil.rmtree, self.tree, True)
        with open(os.path.join(self.tree, "a"), "w", encoding="utf-8") as handle:
            handle.write("x")
        os.symlink("a", os.path.join(self.tree, "link"))

    def run_script(self, env=None):
        import subprocess
        shell = shutil.which("dash") or shutil.which("sh")
        return subprocess.run([shell, self.SCRIPT, self.tree], capture_output=True, text=True, env=env, timeout=30)

    def test_prints_exactly_the_two_lines(self):
        result = self.run_script()
        self.assertEqual(0, result.returncode, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(2, len(lines))
        self.assertEqual("entries 2", lines[0])
        self.assertRegex(lines[1], r"^shape [0-9a-f]{64}$")

    def test_a_failed_readlink_fails_the_digest(self):
        # Mira's catch on #788: the inner shell used to print the NUL anyway.
        bin_dir = tempfile.mkdtemp(prefix="carry-shape-bin-")
        self.addCleanup(shutil.rmtree, bin_dir, True)
        fake = os.path.join(bin_dir, "readlink")
        with open(fake, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\nexit 1\n")
        os.chmod(fake, 0o755)
        env = dict(os.environ, PATH=bin_dir + os.pathsep + os.environ.get("PATH", ""))
        result = self.run_script(env=env)
        self.assertNotEqual(0, result.returncode)
        self.assertNotIn("shape ", result.stdout)
