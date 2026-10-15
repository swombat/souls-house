"""No Docker, SSH, credentials, network, or production DB used by these tests."""
import importlib.util
import json
import shutil
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import call, patch

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

    def test_owner_inputs_reach_the_host_only_through_env(self):
        workflows = OPS.parents[1] / ".github/workflows"
        transport = (workflows / "deploy-house.yml").read_text()
        script = transport.split("run: |", 1)[1]
        self.assertNotIn("${{", script)  # inputs are never interpolated into shell
        self.assertIn("ACCEPT_MIGRATIONS: ${{ inputs.accept_migrations }}", transport)
        self.assertIn("ACKNOWLEDGE_JOB: ${{ inputs.acknowledge_failed_job }}", transport)
        for name in ["deploy-chaos.yml", "deploy-both.yml"]:
            caller = (workflows / name).read_text()
            self.assertIn("accept_migrations: ${{ inputs.accept_migrations }}", caller)
        for name in ["deploy-chaos.yml", "deploy-both.yml", "deploy-runtime.yml", "deploy-rails.yml"]:
            self.assertIn("acknowledge_failed_job: ${{ inputs.acknowledge_failed_job }}",
                          (workflows / name).read_text())
        automatic = (workflows / "deploy-rails-on-green.yml").read_text()
        self.assertNotIn("acknowledge", automatic)
        self.assertNotIn("accept_migrations", automatic)

    def run_transport(self, ssh_script, **env):
        """Execute the checked-in transport script with a fake ssh on PATH."""
        transport = (OPS.parents[1] / ".github/workflows/deploy-house.yml").read_text()
        block = transport.split("        run: |\n", 1)[1].split("\n      # Marker steps", 1)[0]
        script = "\n".join(line[10:] for line in block.splitlines())
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "ssh"
            fake.write_text("#!/bin/bash\n" + ssh_script)
            fake.chmod(0o755)
            summary = Path(directory) / "summary"
            base = dict(PATH=f"{directory}:{os.environ['PATH']}", DEPLOY_KEY="k",
                        DEPLOY_KNOWN_HOSTS="h", DEPLOY_HOST="host.example", DEPLOY_PORT="22",
                        GITHUB_STEP_SUMMARY=str(summary), GITHUB_OUTPUT=str(Path(directory) / "out"),
                        OPERATION="chaos", EXPECTED_REVISION="", ACCEPT_MIGRATIONS="",
                        ACKNOWLEDGE_JOB="")
            base.update(env)
            result = subprocess.run(["bash", "-c", script], env=base, capture_output=True, text=True)
            calls = (Path(directory) / "calls").read_text() if (Path(directory) / "calls").exists() else ""
            return result, calls

    def test_refused_acknowledgement_stops_before_any_request(self):
        result, calls = self.run_transport(
            'echo "${@: -1}" >> "$(dirname "$0")/calls"\n'
            'case "${@: -1}" in acknowledge*) echo "Deployment request unavailable" >&2; exit 1;; esac\n'
            'echo \'{"id":"' + "b" * 32 + '","state":"success"}\'\n',
            ACKNOWLEDGE_JOB="a" * 32)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(["acknowledge " + "a" * 32], calls.splitlines())

    def test_accepted_acknowledgement_then_requests_with_acceptance(self):
        entry = "srv/daemon/migrations/001_init.sql@" + "1" * 40
        result, calls = self.run_transport(
            'echo "${@: -1}" >> "$(dirname "$0")/calls"\n'
            'echo \'{"id":"' + "b" * 32 + '","state":"success"}\'\n',
            ACKNOWLEDGE_JOB="a" * 32, ACCEPT_MIGRATIONS=entry)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(["acknowledge " + "a" * 32, "chaos accept " + entry, "status " + "b" * 32],
                         calls.splitlines())

    def test_superseded_is_a_failed_github_job_not_a_green_nothing(self):
        # #313: host superseded with GitHub success looks like a deploy.
        transport = (OPS.parents[1] / ".github/workflows/deploy-house.yml").read_text()
        superseded = transport.split("superseded)")[1].split("failed|partial|interrupted)")[0]
        self.assertIn("outcome=superseded", superseded)
        self.assertIn("exit 1", superseded)
        self.assertNotIn("exit 0", superseded)
        deployed = transport.split("success)")[1].split("superseded)")[0]
        self.assertIn("exit 0", deployed)
        marker = next(block for block in transport.split("- name: ")
                      if block.startswith("Master moved on, nothing deployed"))
        self.assertIn("failure() && steps.request.outputs.outcome == 'superseded'", marker)
        self.assertNotIn("if: steps.request.outputs.outcome == 'superseded'\n", marker)


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

    def test_chaos_may_carry_reviewed_migration_changes(self):
        entry = "srv/daemon/migrations/001_init.sql@" + "1" * 40
        two = entry + ",var/proc/db/migrate/sqlite/0001_bigbang.sql@" + "2" * 40
        for args in [["chaos", "accept", entry], ["both", "accept", two]]:
            self.assertTrue(gate.valid_args(args), args)
        for args in [["rails", "accept", entry], ["runtime", "accept", entry],
                     ["chaos", "accept", ""], ["chaos", "accept", entry + "," + entry],
                     ["chaos", "accept", "../etc/x.sql@" + "1" * 40],
                     ["chaos", "accept", "a/../b.sql@" + "1" * 40],
                     ["chaos", "accept", "x.rb@" + "1" * 40],
                     ["chaos", "accept", "x.sql@" + "1" * 39],
                     ["chaos", "accept", ",".join(f"m{i}.sql@{'1' * 40}" for i in range(21))],
                     ["chaos", "accept", entry, "extra"]]:
            self.assertFalse(gate.valid_args(args), args)

    def test_accepted_changes_are_recorded_and_returned(self):
        accepted = ["srv/daemon/migrations/001_init.sql@" + "1" * 40]
        with patch.object(gate.subprocess, "run"):
            result = gate.request("chaos", accepted=accepted)
        with patch.object(gate, "active", return_value=True):
            self.assertEqual(accepted, gate.status(result["id"])["accepted_migrations"])
            with self.assertRaises(RuntimeError):
                gate.request("chaos")  # a running job with other acceptances is not joined

    def test_acknowledge_releases_only_the_named_exited_failure(self):
        job_id = self.job("failed")
        with patch.object(gate, "active", return_value=False), \
             patch.object(gate, "exited", return_value=True):
            with self.assertRaises(RuntimeError):
                gate.acknowledge("b" * 32)
            self.assertTrue(gate.acknowledge(job_id)["acknowledged"])
            self.assertFalse((self.root / "current.json").exists())
            self.assertTrue((self.root / "runs" / job_id / "acknowledged-current.json").exists())
            with patch.object(gate.subprocess, "run"):
                self.assertEqual("starting", gate.request("rails")["state"])

    def test_acknowledge_refuses_running_successful_or_still_exiting_jobs(self):
        for state, running in [("running", True), ("success", False), ("failed", True)]:
            shutil.rmtree(self.root / "runs" / ("a" * 32), ignore_errors=True)
            job_id = self.job(state)
            with patch.object(gate, "active", return_value=running), \
                 patch.object(gate, "exited", return_value=not running):
                with self.assertRaises(RuntimeError, msg=state):
                    gate.acknowledge(job_id)
            self.assertTrue((self.root / "current.json").exists())

    def test_only_a_positively_exited_unit_counts_as_exited(self):
        def unit(stdout, returncode=0):
            return subprocess.CompletedProcess([], returncode, stdout=stdout, stderr="")
        for result, expected in [(unit("inactive\n"), True), (unit("failed\n"), True),
                                 (unit("deactivating\n"), False), (unit("activating\n"), False),
                                 (unit("active\n"), False), (unit("reloading\n"), False),
                                 (unit(""), False), (unit("inactive\n", 1), False)]:
            with patch.object(gate.subprocess, "run", return_value=result):
                self.assertEqual(expected, gate.exited("chaos"), result)

    def test_failed_job_still_deactivating_is_not_acknowledged(self):
        job_id = self.job("failed")
        deactivating = subprocess.CompletedProcess([], 3, stdout="deactivating\n", stderr="")
        with patch.object(gate.subprocess, "run", return_value=deactivating):
            with self.assertRaises(RuntimeError):
                gate.acknowledge(job_id)
        self.assertTrue((self.root / "current.json").exists())

    def test_forced_command_admits_accept_and_acknowledge_shapes(self):
        import re
        grammar = re.search(r're\.fullmatch\(r"(.+?)", command\)', (OPS / "ssh-command").read_text())[1]
        for command in ["acknowledge " + "a" * 32, "chaos accept x/y.sql@" + "1" * 40,
                        "both accept a.sql@" + "1" * 40 + ",b.sql@" + "2" * 40]:
            self.assertTrue(re.fullmatch(grammar, command), command)
        for command in ["acknowledge " + "a" * 31, "rails accept a.sql@" + "1" * 40,
                        "chaos accept a.sql;id", "chaos accept a b"]:
            self.assertFalse(re.fullmatch(grammar, command), command)

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

    def test_accepted_migration_change_passes_only_as_the_exact_listed_blob(self):
        path, sha = "srv/daemon/migrations/001_init.sql", "1" * 40
        runtime = {"var/proc/db/migrate/sqlite/0001.sql": "a" * 40}
        before = self.tree(**{path: sha}, **runtime)
        after = self.tree(**runtime)
        with self.assertRaises(worker.MigrationsChanged) as refused:
            worker.verify_migrations(before, after)
        self.assertEqual([f"{path}@{sha}"], refused.exception.changes)
        worker.verify_migrations(before, after, [f"{path}@{sha}"])
        # Same path at another blob, or an unlisted change alongside, still refuses.
        for b, a, accepted in [
                (self.tree(**{path: "2" * 40}, **runtime), after, [f"{path}@{sha}"]),
                (before, self.tree(), [f"{path}@{sha}"])]:
            with self.assertRaisesRegex(RuntimeError, "migrations changed"):
                worker.verify_migrations(b, a, accepted)

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

    def pinned_fixture(self, refs, running="chaos 47.11.0.1", missing=(), inactive=(), on_vm=(),
                       vm=None):
        """vm maps a VM resident's id to the answers its Rails script gives:
        "image" (what its runner last confirmed, None when unreachable), and
        lists of "start" and "status" results consumed in order."""
        self.w.settings.update(custom_residents={}, stock_repositories=["stock"],
                               stock_repository="stock", stock_aliases=["stock:latest"],
                               development_repository="dev", idle_wait_seconds=0)
        residents = [dict(id=i, container_name=f"r{i}", container_image=f"stock:{i}",
                          active=i not in inactive, on_vm=i in on_vm)
                     for i in range(len(refs))]
        labels = {f"stock:{i}": ref for i, ref in enumerate(refs)}
        vm = {i: dict(answers) for i, answers in (vm or {}).items()}
        for i, answers in vm.items():
            if answers.get("image"):
                labels[answers["image"]] = answers.pop("ref", refs[i])
        self.vm_calls = []
        commands = []

        def run(args, **kwargs):
            commands.append(args)
            if args[:2] == ["docker", "exec"]:
                return running
            if "--version" in args:
                return "chaos 47.11.0.1"
            if args[:4] == ["docker", "image", "inspect", "--format"]:
                return self.BUILT
            return None

        def rails(code, env=None):
            if env is None:
                return {"residents": residents}
            if "DEPLOY_VM_MODE" not in env:
                return {"result": "healthy"}
            self.vm_calls.append(env)
            answers = vm[int(env["DEPLOY_RESIDENT_ID"])]
            if env["DEPLOY_VM_MODE"] == "inspect":
                return {"result": "inspected", "running": bool(answers.get("image")),
                        "image": answers.get("image")}
            return answers[env["DEPLOY_VM_MODE"]].pop(0)
        patches = [
            patch.object(worker, "github", side_effect=AssertionError("pinned must not ask upstream")),
            patch.object(self.w, "rails", side_effect=rails),
            patch.object(self.w, "inspect_image", side_effect=lambda image:
                         {"Config": {"Labels": {"house.souls.chaos-ref": labels[image]}}}),
            patch.object(self.w, "run", side_effect=run),
            patch.object(self.w, "check_runtime_permissions"),
            patch.object(self.w, "container_exists",
                         side_effect=lambda name: int(name[1:]) not in missing),
            patch.object(worker, "CODE", self.root),
            patch.object(worker.time, "sleep"),
        ]
        (self.root / "roll-resident.rb").write_text("")
        (self.root / "roll-vm-resident.rb").write_text("")
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        return commands

    RUNNING = "sha256:" + "1" * 64
    BUILT = "sha256:" + "2" * 64

    def update_fixture(self, accepted=None):
        """Update Chaos from c... to n..., where upstream deleted one applied migration."""
        self.pinned_fixture(["c" * 40])
        old, new = "c" * 40, "e" * 40
        gone = "srv/daemon/migrations/001_init.sql"
        trees = {old: {"truncated": False, "tree": [{"path": gone, "sha": "1" * 40, "type": "blob"}]},
                 new: {"truncated": False, "tree": []}}

        def github(path):
            if path == "commits/master":
                return {"sha": new}
            if path.startswith("releases"):
                name = f"chaos-linux-x86_64-{new}.tar.gz"
                return [dict(tag_name="build-" + new, draft=False, published_at="2026-10-14",
                             assets=[{"name": name}, {"name": name + ".sha256"}])]
            if path.startswith("compare/"):
                return {"status": "ahead"}
            return trees[path.split("/")[2].split("?")[0]]
        p = patch.object(worker, "github", side_effect=github)
        p.start()
        self.addCleanup(p.stop)
        if accepted:
            self.w.data["accepted_migrations"] = accepted
        return f"{gone}@{'1' * 40}"

    def test_refused_update_publishes_the_exact_changes_to_accept(self):
        change = self.update_fixture()
        with self.assertRaisesRegex(RuntimeError, "migrations changed"):
            self.w.update_chaos()
        self.assertEqual([change], self.w.data["migration_changes"])
        self.assertIn("migration_changes", gate.FIELDS)
        self.assertNotIn("docker", " ".join(" ".join(c) for c in self.w.run.call_args_list
                                             for c in [c.args[0]]))

    def test_update_with_the_accepted_change_rolls_out(self):
        change = self.update_fixture()
        self.w.data["accepted_migrations"] = [change]
        self.w.update_chaos()
        self.assertEqual("e" * 40, self.w.data["chaos_revision"])
        self.assertEqual("all residents healthy", self.w.data["step"])

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

    def test_inactive_resident_without_container_is_left_alone(self):
        commands = self.pinned_fixture(["c" * 40, "c" * 40], missing=(1,), inactive=(1,))
        self.w.rebuild_residents()
        self.assertEqual("all residents healthy", self.w.data["step"])
        self.assertEqual([1], self.w.data["absent"])
        touched = [c for c in commands if c[:2] == ["docker", "exec"]]
        self.assertTrue(touched)
        self.assertFalse(any("r1" in c for c in touched))
        rolled = [call.args[1]["DEPLOY_RESIDENT_ID"] for call in self.w.rails.call_args_list
                  if call.args[1:]]
        self.assertEqual(["0"], rolled)

    def test_inactive_resident_on_its_own_vm_is_left_alone(self):
        # A retired throwaway: nothing here to probe, and nothing to roll there.
        commands = self.pinned_fixture(["c" * 40, "c" * 40], missing=(1,), on_vm=(1,), inactive=(1,))
        self.w.rebuild_residents()
        self.assertEqual("all residents healthy", self.w.data["step"])
        self.assertEqual([1], self.w.data["on_vm"])
        self.assertNotIn(call("r1"), self.w.container_exists.call_args_list)
        self.assertFalse(any("r1" in c for c in commands if c[:2] == ["docker", "exec"]))
        self.assertEqual([], self.vm_calls)
        rolled = [c.args[1]["DEPLOY_RESIDENT_ID"] for c in self.w.rails.call_args_list if c.args[1:]]
        self.assertEqual(["0"], rolled)

    def vm_fixture(self, start, status=(), image=None, ref=None, refs=("c" * 40, "c" * 40)):
        answers = dict(image=image or self.RUNNING, start=list(start), status=list(status))
        if ref:
            answers["ref"] = ref
        return self.pinned_fixture(list(refs), missing=(1,), on_vm=(1,), vm={1: answers})

    def test_active_resident_on_its_own_vm_gets_the_built_image_by_id(self):
        commands = self.vm_fixture(start=[{"result": "started", "command_id": 77}],
                                   status=[{"result": "pending"}, {"result": "healthy"}])
        self.w.rebuild_residents()
        self.assertEqual("all residents healthy", self.w.data["step"])
        # Never probed or exec'd here: its container is on the VM.
        self.assertNotIn(call("r1"), self.w.container_exists.call_args_list)
        self.assertFalse(any("r1" in c for c in commands if c[:2] == ["docker", "exec"]))
        # The binary it runs now is read from the image its runner confirmed.
        self.assertIn(["docker", "run", "--rm", "--network", "none", "--entrypoint", "chaos",
                       self.RUNNING, "--version"], commands)
        modes = [env["DEPLOY_VM_MODE"] for env in self.vm_calls]
        self.assertEqual(["inspect", "start", "status", "status"], modes)
        start = self.vm_calls[1]
        self.assertEqual(self.BUILT, start["DEPLOY_RESIDENT_IMAGE_ID"])
        self.assertEqual("stock:deploy-" + "a" * 32, start["DEPLOY_RESIDENT_IMAGE"])
        self.assertEqual("77", self.vm_calls[2]["DEPLOY_VM_COMMAND_ID"])
        # Host residents first, then the VM; the alias moves only after both.
        self.assertEqual(["docker", "tag", "stock:deploy-" + "a" * 32, "stock:latest"], commands[-1])

    def test_vm_resident_already_on_the_image_is_current(self):
        self.vm_fixture(start=[{"result": "current"}])
        self.w.rebuild_residents()
        self.assertEqual("all residents healthy", self.w.data["step"])
        self.assertEqual(["inspect", "start"], [env["DEPLOY_VM_MODE"] for env in self.vm_calls])

    def test_unreachable_vm_resident_is_skipped_and_the_run_is_partial(self):
        commands = self.pinned_fixture(["c" * 40, "c" * 40], missing=(1,), on_vm=(1,),
                                       vm={1: dict(image=None)})
        self.w.rebuild_residents()
        self.assertEqual("partial", self.w.data["state"])
        self.assertEqual([1], self.w.data["skipped"])
        self.assertEqual(["inspect"], [env["DEPLOY_VM_MODE"] for env in self.vm_calls])
        self.assertFalse(any(c[:2] == ["docker", "tag"] for c in commands))

    def assert_vm_resident_skipped(self, answer):
        commands = self.vm_fixture(start=[{"result": answer}])
        self.w.rebuild_residents()
        self.assertEqual("partial", self.w.data["state"])
        self.assertEqual([1], self.w.data["skipped"])
        self.assertNotIn("status", [env["DEPLOY_VM_MODE"] for env in self.vm_calls])
        self.assertFalse(any(c[:2] == ["docker", "tag"] for c in commands))

    def test_busy_vm_resident_is_skipped(self):
        self.assert_vm_resident_skipped("busy")

    def test_vm_resident_unreachable_at_start_is_skipped(self):
        self.assert_vm_resident_skipped("unavailable")

    def test_failed_vm_restart_stops_the_run_without_moving_the_alias(self):
        commands = self.vm_fixture(start=[{"result": "started", "command_id": 77}],
                                   status=[{"result": "failed"}])
        with self.assertRaisesRegex(RuntimeError, "turns stay held"):
            self.w.rebuild_residents()
        self.assertFalse(any(c[:2] == ["docker", "tag"] for c in commands))

    def test_vm_restart_that_never_settles_stops_the_run(self):
        self.w.settings["vm_restart_wait_seconds"] = 0
        commands = self.vm_fixture(start=[{"result": "started", "command_id": 77}],
                                   status=[{"result": "pending"}])
        with self.assertRaisesRegex(RuntimeError, "did not settle"):
            self.w.rebuild_residents()
        self.assertFalse(any(c[:2] == ["docker", "tag"] for c in commands))

    def test_rebuild_reads_the_revision_a_vm_actually_runs(self):
        # Its tag here says c..., but the image its runner confirmed is d...
        commands = self.vm_fixture(start=[], ref="d" * 40)
        with self.assertRaisesRegex(RuntimeError, "different Chaos revisions"):
            self.w.rebuild_residents()
        self.assertFalse(any(c[:2] == ["docker", "build"] for c in commands))

    def test_custom_runtime_is_never_sent_to_a_vm(self):
        commands = self.vm_fixture(start=[])
        self.w.settings["custom_residents"] = {"1": "development"}
        with self.assertRaisesRegex(RuntimeError, "Custom runtime on a VM"):
            self.w.rebuild_residents()
        self.assertEqual([], self.vm_calls)
        self.assertFalse(any(c[:2] == ["docker", "build"] for c in commands))

    def test_install_ships_the_vm_restart_script(self):
        self.assertIn("roll-vm-resident.rb", (OPS / "install").read_text())

    def test_rails_query_marks_residents_on_their_own_vm(self):
        source = (OPS / "worker.py").read_text()
        self.assertIn("'on_vm'=>a.placement&.backend=='hetzner_cloud'", source)

    def test_active_resident_without_container_stops_before_building(self):
        commands = self.pinned_fixture(["c" * 40, "c" * 40], missing=(1,))
        with self.assertRaisesRegex(RuntimeError, "Active resident has no container"):
            self.w.rebuild_residents()
        self.assertFalse(any(c[:2] == ["docker", "build"] for c in commands))

    def test_container_probe_distinguishes_absent_from_docker_failure(self):
        def fake(stderr, code):
            return patch.object(worker.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], code, stdout="", stderr=stderr))
        with fake("", 0):
            self.assertTrue(self.w.container_exists("r0"))
        with fake("Error response from daemon: No such container: r0", 1):
            self.assertFalse(self.w.container_exists("r0"))
        with fake("Cannot connect to the Docker daemon", 1):
            with self.assertRaisesRegex(RuntimeError, "private diagnostics"):
                self.w.container_exists("r0")

    def test_absent_is_a_public_status_field(self):
        self.assertIn("absent", gate.FIELDS)

    def test_permission_preflight_uses_resident_user_without_network(self):
        with patch.object(self.w, "run") as run:
            self.w.check_runtime_permissions("fixture:image")
        args = run.call_args.args[0]
        self.assertEqual("agent", args[args.index("--user") + 1])
        self.assertEqual("none", args[args.index("--network") + 1])
        self.assertIn("p.read_bytes()", args[-1])


if __name__ == "__main__":
    unittest.main()
