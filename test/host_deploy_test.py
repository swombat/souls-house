"""No Docker, SSH, credentials, network, or production DB used by these tests."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

OPS = Path(__file__).resolve().parents[1] / "ops/deploy"
sys.path.insert(0, str(OPS))
import gate
import worker


class GateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "runs").mkdir()
        self.patch = patch.object(gate, "ROOT", self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def job(self, state="running", operation="rails"):
        job_id = "a" * 32
        path = self.root / "runs" / job_id
        path.mkdir()
        data = dict(id=job_id, state=state, operation=operation, step="test", secret="never return")
        gate.atomic(path / "status.json", data)
        gate.atomic(self.root / "current.json", data)
        return job_id

    def test_exact_command_grammar(self):
        for args in [["rails"], ["chaos"], ["both"], ["status", "a" * 32]]:
            self.assertTrue(gate.valid_args(args))
        for args in [[], ["rails", "--help"], ["rails;id"], ["status", "../secret"],
                     ["status", "A" * 32], ["status", "a" * 31], ["status", "a" * 32, "extra"]]:
            self.assertFalse(gate.valid_args(args))

    def test_forced_command_refuses_before_sudo(self):
        for command in ["", "bash", "rails; id", "rails\n", " rails", "status ../../etc/passwd"]:
            result = subprocess.run([sys.executable, str(OPS / "ssh-command")],
                                    env={"SSH_ORIGINAL_COMMAND": command},
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Unsupported", result.stderr)

    def test_fixed_unit_start_and_private_permissions(self):
        with patch.object(gate.subprocess, "run") as run:
            result = gate.request("rails")
        self.assertEqual("starting", result["state"])
        self.assertRegex(result["id"], "^[0-9a-f]{32}$")
        self.assertEqual(run.call_args.args[0],
                         ["/usr/bin/systemctl", "start", "house-deploy-rails.service"])
        self.assertEqual(0o700, (self.root / "runs" / result["id"]).stat().st_mode & 0o777)

    def test_same_operation_attaches_without_start(self):
        job_id = self.job()
        with patch.object(gate, "active", return_value=True), patch.object(gate.subprocess, "run") as run:
            self.assertEqual(job_id, gate.request("rails")["id"])
            run.assert_not_called()
            with self.assertRaises(RuntimeError):
                gate.request("chaos")

    def test_status_projection_cannot_expose_private_fields(self):
        job_id = self.job()
        with patch.object(gate, "active", return_value=True):
            self.assertNotIn("secret", gate.status(job_id))

    def test_crashed_worker_is_interrupted_not_success_or_retry(self):
        job_id = self.job()
        with patch.object(gate, "active", return_value=False):
            self.assertEqual("interrupted", gate.status(job_id)["state"])
            with self.assertRaises(RuntimeError):
                gate.request("rails")

    def test_terminal_but_not_exited_worker_cannot_lose_new_request(self):
        self.job("success")
        with patch.object(gate, "active", return_value=True):
            with self.assertRaises(RuntimeError):
                gate.request("rails")

    def test_failed_worker_requires_operator_even_after_unit_exits(self):
        self.job("failed")
        with patch.object(gate, "active", return_value=False):
            with self.assertRaises(RuntimeError):
                gate.request("rails")

    def test_failed_unit_start_is_failed(self):
        with patch.object(gate.subprocess, "run", side_effect=subprocess.CalledProcessError(1, [])):
            self.assertEqual("failed", gate.request("rails")["state"])


class ReleaseTest(unittest.TestCase):
    def tree(self, **paths):
        return {"truncated": False, "tree": [
            {"path": path, "sha": sha, "type": "blob"} for path, sha in paths.items()]}

    def test_complete_migration_check_allows_additions(self):
        before = self.tree(**{"db/migrations/001.sql": "a"})
        after = self.tree(**{"db/migrations/001.sql": "a", "db/migrations/002.sql": "b",
                             **{f"src/{i}.rs": "changed" for i in range(350)}})
        worker.verify_migrations(before, after)

    def test_complete_migration_check_refuses_edits_deletions_and_renames(self):
        before = self.tree(**{"db/migrations/001.sql": "a"})
        for after in [self.tree(), self.tree(**{"db/migrations/001.sql": "b"}),
                      self.tree(**{"db/migrations/renamed.sql": "a"})]:
            with self.assertRaisesRegex(RuntimeError, "migrations changed"):
                worker.verify_migrations(before, after)

    def test_incomplete_or_unmarked_tree_fails_closed(self):
        good = self.tree()
        for bad in [{"truncated": True, "tree": []}, {"tree": []}]:
            for before, after in [(bad, good), (good, bad)]:
                with self.assertRaisesRegex(RuntimeError, "tree incomplete"):
                    worker.verify_migrations(before, after)

    def test_checks_upstream_migrate_directories_as_well_as_migrations(self):
        before = self.tree(**{"var/proc/db/migrate/sqlite/0001.sql": "a",
                              "var/proc/db/migrate/postgres/0001.sql": "b"})
        with self.assertRaisesRegex(RuntimeError, "migrations changed"):
            worker.verify_migrations(before, self.tree())

    def release(self, sha="a" * 40, date="2026-10-03"):
        name = f"chaos-linux-x86_64-{sha}.tar.gz"
        return dict(tag_name="build-" + sha, draft=False, published_at=date,
                    assets=[{"name": name}, {"name": name + ".sha256"}])

    def test_selects_newest_published_mainline_artifact(self):
        first, second = self.release(date="2026-10-01"), self.release("b" * 40)
        self.assertEqual("b" * 40, worker.published_revision([first, second], lambda _: True))

    def test_skips_draft_missing_asset_and_off_mainline(self):
        draft = self.release(); draft["draft"] = True
        missing = self.release(); missing["assets"].pop()
        old = self.release("c" * 40, "2026-10-01")
        self.assertEqual("c" * 40, worker.published_revision(
            [draft, missing, self.release("b" * 40), old], lambda sha: sha == "c" * 40))

    def test_no_artifact_is_failure_not_source_fallback(self):
        with self.assertRaises(RuntimeError):
            worker.published_revision([], lambda _: True)
        self.assertLess(worker.version_tuple("chaos 47.9.0"), worker.version_tuple("chaos 47.10.0"))
        with self.assertRaises(RuntimeError):
            worker.version_tuple("chaos arbitrary shell")


class WorkerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        config = self.root / "config"
        config.mkdir()
        (config / "settings.json").write_text("{}")
        (self.root / "runs" / ("a" * 32)).mkdir(parents=True)
        initial = dict(id="a" * 32, operation="both", state="starting", step="accepted")
        gate.atomic(self.root / "current.json", initial)
        gate.atomic(self.root / "runs" / ("a" * 32) / "status.json", initial)
        self.patches = [patch.object(worker, "ROOT", self.root), patch.object(worker, "CONFIG", config)]
        for p in self.patches:
            p.start()
            self.addCleanup(p.stop)
        self.w = worker.Worker("both")
        self.addCleanup(lambda: self.w.log.close())

    def test_both_stops_if_rails_fails_and_never_exposes_error(self):
        with patch.object(self.w, "checkout"), \
             patch.object(self.w, "deploy_rails", side_effect=RuntimeError("SECRET")), \
             patch.object(self.w, "update_chaos") as runtime:
            self.w.execute()
        runtime.assert_not_called()
        self.assertEqual("failed", self.w.data["state"])
        self.assertNotIn("SECRET", json.dumps(self.w.data))
        self.assertIn("SECRET", (self.w.directory / "private.log").read_text())

    def test_partial_is_not_overwritten_with_success(self):
        with patch.object(self.w, "checkout"), patch.object(self.w, "deploy_rails"), \
             patch.object(self.w, "update_chaos",
                          side_effect=lambda: self.w.report("busy", state="partial", skipped=[7])):
            self.w.execute()
        self.assertEqual("partial", self.w.data["state"])

    def test_worker_lock_rejects_overlap(self):
        import fcntl
        with (self.root / "deployment.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.object(self.w, "checkout") as checkout:
                self.w.execute()
            checkout.assert_not_called()
        self.assertEqual("failed", self.w.data["state"])

    def test_success_only_after_both_phases(self):
        calls = []
        with patch.object(self.w, "checkout", side_effect=lambda: calls.append("checkout")), \
             patch.object(self.w, "deploy_rails", side_effect=lambda: calls.append("rails")), \
             patch.object(self.w, "update_chaos", side_effect=lambda: calls.append("chaos")):
            self.w.execute()
        self.assertEqual(["checkout", "rails", "chaos"], calls)
        self.assertEqual("success", self.w.data["state"])

    def test_subprocess_error_is_private(self):
        with patch.object(worker.subprocess, "run",
                          return_value=subprocess.CompletedProcess([], 1, "SECRET", "OTHER SECRET")):
            with self.assertRaises(RuntimeError) as error:
                self.w.run(["fixture"])
        self.assertNotIn("SECRET", str(error.exception))

    def test_manual_service_restart_cannot_replay_completed_job(self):
        self.w.report("verified", state="success")
        with self.assertRaises(RuntimeError):
            worker.Worker("both")

    def test_kamal_timeout_removes_only_its_named_container(self):
        self.w.settings["tools_image"] = "fixture"
        with patch.object(self.w, "run",
                          side_effect=[subprocess.TimeoutExpired("docker", 7200), None]) as run:
            with self.assertRaises(subprocess.TimeoutExpired):
                self.w.kamal("deploy")
        name = "house-deploy-kamal-" + self.w.data["id"]
        self.assertIn(name, run.call_args_list[0].args[0])
        self.assertEqual(["docker", "rm", "-f", name], run.call_args_list[1].args[0])


if __name__ == "__main__":
    unittest.main()
