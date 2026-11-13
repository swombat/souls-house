"""The backup's own Postgres dump, its persistent restic cache and the
transcripts mount (13 Nov: VM backup cadence, loud latch, transcripts)."""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "host-runner"))

import backup_proxy as backup
from souls_house_runner import CommandFailed
from backup_proxy_test import FakeDocker, FakeHost, FakeProxy, payload

DATABASES = ["resident_main", "resident_oauth"]


class MountDocker(FakeDocker):
    """Answers mountpoint lookups from a map and records cache creation."""

    def __init__(self, mountpoints=None, cache_exists=True, cache_create_ok=True):
        super().__init__()
        self.mountpoints = mountpoints or {}
        self.cache_exists = cache_exists
        self.cache_create_ok = cache_create_ok

    def __call__(self, argv, timeout=120):
        if argv[1:3] == ["volume", "inspect"] and "--format" in argv:
            self.calls.append((list(argv), timeout))
            path = self.mountpoints.get(argv[-1])
            return (path is not None), (path or "")
        if argv[1:3] == ["volume", "inspect"] and argv[-1].endswith("-restic-cache"):
            self.calls.append((list(argv), timeout))
            return self.cache_exists, ""
        if argv[1:3] == ["volume", "create"]:
            self.calls.append((list(argv), timeout))
            self.cache_exists = self.cache_create_ok
            return self.cache_create_ok, ""
        return super().__call__(argv, timeout)


def run(docker, postgres=lambda *args: {"state": "absent"}):
    return backup.run_backup(payload(), FakeHost(), signed_request=lambda *a, **kw: (200, {}, b""),
                             docker=docker, proxy_factory=FakeProxy, postgres=postgres)


def restic_mounts(docker):
    argv = next(argv for argv, _ in docker.calls if argv[1] == "run" and "backup" in argv)
    return [argv[i + 1] for i, value in enumerate(argv) if value == "--mount"]


class TranscriptsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = os.path.join(self.temp.name, "state")
        os.makedirs(self.state)
        self.docker = MountDocker({"agent-pilot-1-state": self.state})

    def tearDown(self):
        self.temp.cleanup()

    def test_claude_projects_alone_is_mounted_read_only_by_subpath(self):
        os.makedirs(os.path.join(self.state, "claude", "projects"))
        os.makedirs(os.path.join(self.state, "claude", "credentials"))
        result = run(self.docker)
        self.assertTrue(result["transcripts"])
        state_mounts = [m for m in restic_mounts(self.docker) if "agent-pilot-1-state" in m]
        self.assertEqual(state_mounts, [
            "type=volume,src=agent-pilot-1-state,dst=/data/state/claude/projects,readonly,"
            "volume-subpath=claude/projects"])
        # Nothing else of the state volume: no whole-volume or other subpath.
        self.assertFalse(any("dst=/data/state," in m or m.endswith("dst=/data/state") for m in restic_mounts(self.docker)))

    def test_absent_or_symlinked_projects_are_not_mounted(self):
        for build in (
            lambda: None,
            lambda: os.makedirs(os.path.join(self.state, "claude")),
            lambda: (os.makedirs(os.path.join(self.state, "claude")),
                     os.symlink("/etc", os.path.join(self.state, "claude", "projects"))),
            lambda: os.symlink("/etc", os.path.join(self.state, "claude")),
        ):
            with self.subTest():
                for entry in os.listdir(self.state):
                    path = os.path.join(self.state, entry)
                    if os.path.islink(path):
                        os.unlink(path)
                    else:
                        import shutil
                        shutil.rmtree(path)
                build()
                self.docker.calls.clear()
                result = run(self.docker)
                self.assertFalse(result["transcripts"])
                self.assertFalse(any("state" in m for m in restic_mounts(self.docker)))

    def test_missing_state_volume_is_not_a_failure(self):
        docker = MountDocker({})
        result = run(docker)
        self.assertFalse(result["transcripts"])
        self.assertEqual(result["snapshot_id"], "d" * 64)


class CacheVolumeTest(unittest.TestCase):
    def test_missing_cache_is_created_before_the_pause(self):
        docker = MountDocker(cache_exists=False)
        run(docker)
        commands = [argv for argv, _ in docker.calls]
        create = commands.index(["docker", "volume", "create", "agent-pilot-1-restic-cache"])
        pause = next(i for i, argv in enumerate(commands) if argv[1] == "pause")
        self.assertLess(create, pause)
        # Only the cache is ever created, never a resident volume.
        self.assertEqual([argv for argv in commands if argv[1:3] == ["volume", "create"]],
                         [["docker", "volume", "create", "agent-pilot-1-restic-cache"]])

    def test_cache_creation_failure_fails_before_any_pause(self):
        docker = MountDocker(cache_exists=False, cache_create_ok=False)
        with self.assertRaises(backup.BackupFailed) as caught:
            run(docker)
        self.assertIn("cache", str(caught.exception))
        self.assertFalse(any(argv[1] in ("pause", "run") for argv, _ in docker.calls))


class DumpOrderTest(unittest.TestCase):
    def test_dump_runs_before_the_pause_and_is_reported(self):
        docker = MountDocker()
        seen = []

        def postgres(name, docker_, seconds):
            seen.append((name, docker.paused, seconds))
            return {"state": "ok", "generation": "20261113T040000Z", "bytes": 10}

        result = run(docker, postgres)
        self.assertEqual(len(seen), 1)
        self.assertEqual(seen[0][0], "agent-pilot-1")
        self.assertFalse(seen[0][1])
        self.assertLessEqual(seen[0][2], backup.PG_DUMP_SECONDS)
        self.assertEqual(result["postgres_dump"]["state"], "ok")

    def test_failed_dump_still_snapshots_everything_else(self):
        docker = MountDocker()
        result = run(docker, lambda *args: {"state": "failed", "reason": "incomplete generation X retained"})
        self.assertEqual(result["snapshot_id"], "d" * 64)
        self.assertEqual(result["postgres_dump"], {"state": "failed", "reason": "incomplete generation X retained"})
        self.assertTrue(result["unpaused"])


class FakePostgres:
    """Stands in for `docker exec souls-house-postgres ...`."""

    def __init__(self, fail_on=None):
        self.calls = []
        self.fail_on = fail_on

    def __call__(self, argv, check, stdout, stderr=None, timeout=None, stdin=None):
        self.calls.append(argv)
        assert timeout and timeout > 0
        assert argv[:2] == ["docker", "exec"] and backup.PG_CONTAINER in argv
        tool = next(part for part in argv if part.startswith("pg_"))
        if self.fail_on == tool:
            raise subprocess.CalledProcessError(1, argv)
        if stdout not in (None, subprocess.DEVNULL):
            stdout.write(f"{tool} {argv[-1]}".encode())
        return subprocess.CompletedProcess(argv, 0)


class DumpPostgresTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.chaos = os.path.join(self.temp.name, "chaos")
        os.makedirs(self.chaos)
        self.config = os.path.join(self.temp.name, "config.json")
        self.write_config()
        self.docker = MountDocker({"agent-pilot-1-chaos": self.chaos})
        self.clock = iter(range(1_800_000_000, 1_900_000_000, 60))

    def tearDown(self):
        self.temp.cleanup()

    def write_config(self, **overrides):
        config = {"home_mount": self.chaos, "databases": DATABASES}
        config.update(overrides)
        with open(self.config, "w") as handle:
            json.dump(config, handle)

    def dump(self, fake=None):
        return backup.dump_postgres("agent-pilot-1", self.docker, 60, config_path=self.config,
                                    run=fake or FakePostgres(), now=lambda: time.gmtime(next(self.clock)))

    def root(self):
        return os.path.join(self.chaos, "postgres-backups")

    def test_absent_config_means_no_postgres(self):
        os.unlink(self.config)
        self.assertEqual(self.dump(), {"state": "absent"})

    def test_dump_verifies_each_database_writes_receipt_and_keeps_two_generations(self):
        fake = FakePostgres()
        names = []
        for _ in range(3):
            answer = self.dump(fake)
            self.assertEqual(answer["state"], "ok", answer)
            names.append(answer["generation"])
        self.assertEqual(sorted(e for e in os.listdir(self.root()) if e[0].isdigit()), names[1:])
        with open(os.path.join(self.root(), "current.json")) as handle:
            current = json.load(handle)
        self.assertEqual(current["generation"], names[-1])
        self.assertEqual(sorted(current["databases"]), DATABASES)
        self.assertFalse(os.path.exists(os.path.join(self.root(), names[-1], ".incomplete")))
        tools = [next(p for p in argv if p.startswith("pg_")) for argv in fake.calls[:5]]
        self.assertEqual(tools, ["pg_dump", "pg_restore", "pg_dump", "pg_restore", "pg_dumpall"])

    def test_failure_latches_and_keeps_evidence(self):
        first = self.dump()
        self.assertEqual(first["state"], "ok")
        failed = self.dump(FakePostgres(fail_on="pg_restore"))
        self.assertEqual(failed["state"], "failed")
        self.assertIn("pg_restore exited 1", failed["reason"])
        incomplete = [e for e in os.listdir(self.root())
                      if os.path.exists(os.path.join(self.root(), e, ".incomplete"))]
        self.assertEqual(len(incomplete), 1)
        # Latched: the next attempt refuses, names the generation, deletes nothing.
        latched = self.dump()
        self.assertEqual(latched["state"], "failed")
        self.assertIn(f"incomplete generation {incomplete[0]} retained", latched["reason"])
        self.assertTrue(os.path.isdir(os.path.join(self.root(), first["generation"])))
        self.assertTrue(os.path.isdir(os.path.join(self.root(), incomplete[0])))

    def test_config_must_name_this_residents_chaos_volume_and_sane_databases(self):
        other = os.path.join(self.temp.name, "other")
        os.makedirs(other)
        for overrides in ({"home_mount": other}, {"databases": []}, {"databases": ["x; drop"]},
                          {"databases": ["a", "a"]}, {"databases": "main"}, {"state_mount": "/x"}):
            with self.subTest(overrides=overrides):
                self.write_config(**overrides)
                answer = self.dump()
                self.assertEqual(answer["state"], "failed")
        self.assertFalse(os.path.exists(self.root()))

    def test_incomplete_marker_latches_even_after_a_receipt(self):
        # Interrupted between the receipt and publishing current.json.
        stuck = os.path.join(self.root(), "20261113T000000Z")
        os.makedirs(stuck)
        for name in ("receipt.json", ".incomplete"):
            with open(os.path.join(stuck, name), "w") as handle:
                handle.write("{}")
        answer = self.dump()
        self.assertEqual(answer["state"], "failed")
        self.assertIn("20261113T000000Z", answer["reason"])
        self.assertTrue(os.path.exists(os.path.join(stuck, ".incomplete")))

    def test_symlinked_backup_root_is_refused(self):
        os.symlink(self.temp.name, self.root())
        answer = self.dump()
        self.assertEqual(answer, {"state": "failed", "reason": "postgres-backups must not be a symlink"})

    def test_timeout_is_a_failure_not_an_exception(self):
        def slow(argv, **kwargs):
            raise subprocess.TimeoutExpired(argv, 1)
        answer = self.dump(slow)
        self.assertEqual(answer["state"], "failed")
        self.assertIn("deadline", answer["reason"])


if __name__ == "__main__":
    unittest.main()
