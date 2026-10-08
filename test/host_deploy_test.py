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


class WorkflowAuthorityTest(unittest.TestCase):
    def test_owner_only_on_original_dispatch_and_rerun(self):
        workflows = OPS.parents[1] / ".github/workflows"
        transport = (workflows / "deploy-house.yml").read_text()
        self.assertNotIn("\nconcurrency:", transport)
        self.assertIn("\n    concurrency:\n      group: production-deploy", transport)
        condition = next(line.strip().removeprefix("if: ") for line in
                         transport.splitlines() if line.strip().startswith("if: "))
        self.assertEqual(
            "github.ref == 'refs/heads/master' && github.actor == 'swombat' "
            "&& github.triggering_actor == 'swombat'", condition)
        # Exercise the actual checked-in expression, not a separate predicate.
        from types import SimpleNamespace
        for ref in ["refs/heads/master", "refs/heads/other"]:
            for actor in ["swombat", "seuros", ""]:
                for triggering_actor in ["swombat", "seuros", ""]:
                    context = SimpleNamespace(ref=ref, actor=actor,
                                              triggering_actor=triggering_actor)
                    allowed = eval(condition.replace("&&", "and"),
                                   {"__builtins__": {}, "github": context})
                    self.assertEqual(
                        ref == "refs/heads/master" and actor == triggering_actor == "swombat",
                        allowed, (ref, actor, triggering_actor))
        for name in ["deploy-rails.yml", "deploy-chaos.yml", "deploy-both.yml",
                     "deploy-runtime.yml"]:
            caller = (workflows / name).read_text()
            self.assertIn("uses: ./.github/workflows/deploy-house.yml", caller)
            self.assertNotIn("runs-on:", caller)

    def test_automatic_deploy_is_rails_only_after_green_master_ci(self):
        caller = (OPS.parents[1] / ".github/workflows/deploy-rails-on-green.yml").read_text()
        self.assertIn("  workflow_run:\n    workflows: [CI]\n    types: [completed]\n    branches: [master]", caller)
        for condition in ["github.event.workflow_run.conclusion == 'success'",
                          "github.event.workflow_run.event == 'push'",
                          "github.event.workflow_run.head_branch == 'master'",
                          "vars.AUTO_DEPLOY_RAILS != 'false'"]:
            self.assertIn(condition, caller)
        self.assertIn("uses: ./.github/workflows/deploy-house.yml", caller)
        self.assertNotIn("runs-on:", caller)
        operations = [line.strip() for line in caller.splitlines() if line.strip().startswith("operation:")]
        self.assertEqual(["operation: rails"], operations)
        # The tested commit travels to the host; nothing else chooses it.
        self.assertIn("expected_revision: ${{ github.event.workflow_run.head_sha }}", caller)
        self.assertIn("cancel-in-progress: false", caller)


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
        for args in [["rails"], ["chaos"], ["both"], ["runtime"], ["status", "a" * 32]]:
            self.assertTrue(gate.valid_args(args))
        for args in [[], ["rails", "--help"], ["rails;id"], ["status", "../secret"],
                     ["status", "A" * 32], ["status", "a" * 31], ["status", "a" * 32, "extra"]]:
            self.assertFalse(gate.valid_args(args))

    def test_rails_alone_may_carry_an_exact_expected_revision(self):
        sha = "c" * 40
        self.assertTrue(gate.valid_args(["rails", "expect", sha]))
        for args in [["chaos", "expect", sha], ["both", "expect", sha], ["rails", "expect", sha[:39]],
                     ["rails", "expect", "C" * 40], ["rails", "expect", "master"],
                     ["rails", "deploy", sha], ["rails", "expect", sha, "extra"]]:
            self.assertFalse(gate.valid_args(args), args)

    def test_forced_command_accepts_expected_revision_only_for_rails(self):
        import re
        grammar = re.search(r're\.fullmatch\(r"(.+?)", command\)', (OPS / "ssh-command").read_text())[1]
        self.assertTrue(re.fullmatch(grammar, "rails expect " + "c" * 40))
        for command in ["chaos expect " + "c" * 40, "rails expect " + "c" * 39, "rails expect master"]:
            self.assertFalse(re.fullmatch(grammar, command), command)

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

    def test_expected_revision_is_recorded_and_returned(self):
        with patch.object(gate.subprocess, "run"):
            result = gate.request("rails", "c" * 40)
        self.assertEqual("c" * 40, result["expected_revision"])
        with patch.object(gate, "active", return_value=True):
            self.assertEqual("c" * 40, gate.status(result["id"])["expected_revision"])

    def test_running_job_with_another_expectation_is_not_joined(self):
        self.job()  # a running rails job with no expectation
        with patch.object(gate, "active", return_value=True), patch.object(gate.subprocess, "run") as run:
            with self.assertRaises(RuntimeError):
                gate.request("rails", "c" * 40)
            run.assert_not_called()

    def test_superseded_is_terminal_and_does_not_block_the_next_request(self):
        self.job("superseded")
        with patch.object(gate, "active", return_value=False), patch.object(gate.subprocess, "run"):
            self.assertEqual("superseded", gate.status("a" * 32)["state"])
            self.assertEqual("starting", gate.request("rails")["state"])

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

    def test_master_moved_on_deploys_nothing(self):
        self.w.data["expected_revision"] = "c" * 40
        self.w.settings["repository"] = "https://example.test/public.git"
        with patch.object(self.w, "run", side_effect=[None, "d" * 40]), \
             patch.object(self.w, "deploy_rails") as rails, patch.object(self.w, "update_chaos") as chaos:
            self.w.execute()
        rails.assert_not_called()
        chaos.assert_not_called()
        self.assertEqual("superseded", self.w.data["state"])
        self.assertEqual("d" * 40, self.w.data["rails_revision"])

    def test_expected_revision_still_at_master_deploys_it(self):
        self.w.data["expected_revision"] = "c" * 40
        self.w.settings["repository"] = "https://example.test/public.git"
        with patch.object(self.w, "run", side_effect=[None, "c" * 40]), \
             patch.object(self.w, "deploy_rails") as rails, patch.object(self.w, "update_chaos"):
            self.w.execute()
        rails.assert_called_once()
        self.assertEqual("success", self.w.data["state"])
        self.assertEqual("c" * 40, self.w.data["rails_revision"])

    def test_only_public_checkout_overrides_private_umask(self):
        self.w.settings["repository"] = "https://example.test/public.git"
        with patch.object(self.w, "run", side_effect=[None, "b" * 40]) as run:
            self.w.checkout()
        self.assertEqual(0o022, run.call_args_list[0].kwargs["umask"])
        self.assertNotIn("umask", run.call_args_list[1].kwargs)

    def test_subprocess_umask_does_not_change_worker_umask(self):
        path = self.root / "public-file"
        previous = os.umask(0o077)
        try:
            self.w.run([sys.executable, "-c",
                        "from pathlib import Path; Path(__import__('sys').argv[1]).touch()", str(path)],
                       umask=0o022)
            private = self.root / "private-file"
            private.touch()
        finally:
            os.umask(previous)
        self.assertEqual(0o644, path.stat().st_mode & 0o777)
        self.assertEqual(0o600, private.stat().st_mode & 0o777)

    def test_every_operation_is_wired_end_to_end(self):
        root = OPS.parents[1]
        transport = (root / ".github/workflows/deploy-house.yml").read_text()
        install = (OPS / "install").read_text()
        for operation in gate.OPERATIONS:
            self.assertIn(f"operation: {operation}", "".join(
                path.read_text() for path in (root / ".github/workflows").glob("deploy-*.yml")))
            self.assertIn(operation, transport.split('case "$OPERATION" in ')[1].split(")")[0])
            self.assertIn(operation, install.split("for operation in ")[1].split(";")[0])
            # Read the forced command's grammar rather than executing it: an
            # accepted command would exec sudo.
            import re
            grammar = re.search(r're\.fullmatch\(r"(.+?)", command\)',
                                (OPS / "ssh-command").read_text())[1]
            self.assertTrue(re.fullmatch(grammar, operation), operation)

    def test_runtime_operation_only_rebuilds_residents(self):
        self.w.data["operation"] = "runtime"
        with patch.object(self.w, "checkout"), patch.object(self.w, "deploy_rails") as rails, \
             patch.object(self.w, "update_chaos") as chaos, \
             patch.object(self.w, "rebuild_residents") as rebuild:
            self.w.execute()
        rails.assert_not_called()
        chaos.assert_not_called()
        rebuild.assert_called_once()
        self.assertEqual("success", self.w.data["state"])

    def pinned_fixture(self, refs, running="chaos 47.11.0.1"):
        self.w.settings.update(custom_residents={}, stock_repositories=["stock"],
                               stock_repository="stock", stock_aliases=["stock:latest"],
                               development_repository="dev", idle_wait_seconds=0)
        residents = [dict(id=i, container_name=f"r{i}", container_image=f"stock:{i}")
                     for i in range(len(refs))]
        labels = {f"stock:{i}": ref for i, ref in enumerate(refs)}
        commands = []

        def run(args, **kwargs):
            commands.append(args)
            if args[:2] == ["docker", "exec"]:
                return running
            if "--version" in args:
                return "chaos 47.11.0.1"
            return None
        patches = [
            patch.object(worker, "github", side_effect=AssertionError("pinned must not ask upstream")),
            patch.object(self.w, "rails", side_effect=lambda code, env=None:
                         {"residents": residents} if env is None else {"result": "healthy"}),
            patch.object(self.w, "inspect_image", side_effect=lambda image:
                         {"Config": {"Labels": {"house.souls.chaos-ref": labels[image]}}}),
            patch.object(self.w, "run", side_effect=run),
            patch.object(self.w, "check_runtime_permissions"),
            patch.object(worker, "CODE", self.root),
        ]
        (self.root / "roll-resident.rb").write_text("")
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        return commands

    def test_rebuild_keeps_the_running_chaos_revision(self):
        commands = self.pinned_fixture(["c" * 40, "c" * 40])
        self.w.rebuild_residents()
        build = next(c for c in commands if c[:2] == ["docker", "build"])
        self.assertIn("CHAOS_HEAD=" + "c" * 40, build)
        self.assertEqual("c" * 40, self.w.data["chaos_revision"])
        self.assertEqual("all residents healthy", self.w.data["step"])

    def test_rebuild_refuses_mixed_revisions(self):
        commands = self.pinned_fixture(["c" * 40, "d" * 40])
        with self.assertRaisesRegex(RuntimeError, "different Chaos revisions"):
            self.w.rebuild_residents()
        self.assertFalse(any(c[:2] == ["docker", "build"] for c in commands))

    def test_rebuild_refuses_a_different_binary_before_rolling_anyone(self):
        self.pinned_fixture(["c" * 40], running="chaos 47.10.0.1")
        with self.assertRaisesRegex(RuntimeError, "differs from the running one"):
            self.w.rebuild_residents()
        self.w.rails.assert_called_once()

    def test_permission_preflight_uses_resident_user_without_network(self):
        with patch.object(self.w, "run") as run:
            self.w.check_runtime_permissions("fixture:image")
        args = run.call_args.args[0]
        self.assertEqual("agent", args[args.index("--user") + 1])
        self.assertEqual("none", args[args.index("--network") + 1])
        self.assertIn("p.read_bytes()", args[-1])


if __name__ == "__main__":
    unittest.main()
