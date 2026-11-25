"""Unit and git-history tests for scripts/ci_plan.py."""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import ci_plan  # noqa: E402


class CiPlanClassificationTest(unittest.TestCase):
    def test_docs_only_skips_heavy_suites(self):
        plan = ci_plan.classify_paths([
            "docs/architecture.md",
            "README.md",
            "AGENTS.md",
            "LICENSE",
            "research/notes.md",
        ])
        self.assertFalse(plan.run_application)
        self.assertFalse(plan.run_frontend)
        self.assertFalse(plan.run_runtime)

    def test_pure_rails_runs_only_application(self):
        plan = ci_plan.classify_paths([
            "app/models/user.rb",
            "app/views/chats/show.html.erb",
            "config/routes.rb",
            "config/changelog/2026-11-25-test.yml",
            "db/schema.rb",
            "lib/tasks/house.rake",
            "test/models/user_test.rb",
            "playwright/tests/chat.spec.js",
            "scripts/run-rails-shard.rb",
        ])
        self.assertTrue(plan.run_application)
        self.assertFalse(plan.run_frontend)
        self.assertFalse(plan.run_runtime)

    def test_frontend_runs_application_and_frontend_without_runtime(self):
        plan = ci_plan.classify_paths([
            "app/frontend/components/user-menu.svelte",
            "vite.config.ts",
        ])
        self.assertTrue(plan.run_application)
        self.assertTrue(plan.run_frontend)
        self.assertFalse(plan.run_runtime)

    def test_pure_python_and_ops_runs_only_runtime(self):
        plan = ci_plan.classify_paths([
            "test/runtime/about_sheet_test.py",
            "test/ci/ci_workflow_test.py",
            "ops/chaos-home/oauth_store_merge.sql",
            "scripts/review-status",
            "patches/example.patch",
        ])
        self.assertFalse(plan.run_application)
        self.assertFalse(plan.run_frontend)
        self.assertTrue(plan.run_runtime)

    def test_runtime_surfaces_with_ruby_tests_run_application_and_runtime(self):
        for path in (
            "agent-runtime/trigger_shim.py",
            "host-runner/souls_house_runner.py",
            "services/telegram-connector/connector.py",
            "ops/deploy/roll-resident.rb",
            "Gemfile.lock",
            ".ruby-version",
            "Dockerfile",
            "playwright/run-backend.rb",
            "test/fixtures/files/rollback_restic_contract.json",
            "bin/instance",
        ):
            with self.subTest(path=path):
                plan = ci_plan.classify_paths([path])
                self.assertTrue(plan.run_application)
                self.assertFalse(plan.run_frontend)
                self.assertTrue(plan.run_runtime)

    def test_cross_cutting_ci_and_js_manifests_run_all_suites(self):
        for path in (
            ".github/workflows/ci.yml",
            ".github/ci/Dockerfile",
            "scripts/ci_plan.py",
            "package.json",
            "bun.lock",
            "config/vite.json",
        ):
            with self.subTest(path=path):
                plan = ci_plan.classify_paths([path])
                self.assertTrue(plan.run_application)
                self.assertTrue(plan.run_frontend)
                self.assertTrue(plan.run_runtime)

    def test_unknown_or_empty_paths_fail_safe_to_all_suites(self):
        for paths in ([], ["   "], ["unknown_dir/file.txt"], ["docs/a.md", "new-top-level.cfg"]):
            with self.subTest(paths=paths):
                plan = ci_plan.classify_paths(paths)
                self.assertTrue(plan.run_application)
                self.assertTrue(plan.run_frontend)
                self.assertTrue(plan.run_runtime)

    def test_mixed_docs_and_python_test_runs_runtime_only(self):
        plan = ci_plan.classify_paths(["docs/overview.md", "test/ci/ci_plan_test.py"])
        self.assertFalse(plan.run_application)
        self.assertFalse(plan.run_frontend)
        self.assertTrue(plan.run_runtime)


class CiPlanDocContractTest(unittest.TestCase):
    def test_doc_contract_checks_active_docs_and_ignores_bak(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "docs" / ".bak").mkdir(parents=True)
            (root / "agent-runtime" / "docs").mkdir(parents=True)
            (root / "docs" / ".bak" / "old.md").write_text("[AGENT-ONLY] legacy\n")
            (root / "docs" / "guide.md").write_text("clean guide\n")
            (root / "AGENTS.md").write_text("clean agents\n")
            self.assertEqual(ci_plan.check_doc_contracts(root), [])

            (root / "docs" / "guide.md").write_text("revived [AGENT-ONLY] tag\n")
            (root / "agent-runtime" / "docs" / "note.md").write_text("[AGENT-ONLY]\n")
            self.assertEqual(
                ci_plan.check_doc_contracts(root),
                ["agent-runtime/docs/note.md", "docs/guide.md"],
            )


class CiPlanGitEventTest(unittest.TestCase):
    def _git(self, repo: Path, *args: str) -> str:
        proc = subprocess.run(
            ["git", *args],
            cwd=repo,
            capture_output=True,
            text=True,
            check=True,
        )
        return proc.stdout.strip()

    def _init_repo(self, repo: Path) -> str:
        self._git(repo, "init", "-b", "master")
        self._git(repo, "config", "user.email", "test@example.com")
        self._git(repo, "config", "user.name", "Test")
        (repo / "README.md").write_text("hello\n")
        self._git(repo, "add", ".")
        self._git(repo, "commit", "-m", "initial")
        base_sha = self._git(repo, "rev-parse", "HEAD")
        self._git(repo, "update-ref", "refs/remotes/origin/master", base_sha)
        return base_sha

    def test_stacked_pr_diffs_against_origin_master_merge_base(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self._init_repo(repo)

            # Base PR branch modifies Rails model.
            self._git(repo, "checkout", "-b", "pr-1")
            (repo / "app" / "models").mkdir(parents=True)
            (repo / "app" / "models" / "widget.rb").write_text("class Widget; end\n")
            self._git(repo, "add", ".")
            self._git(repo, "commit", "-m", "add widget")

            # Stacked PR branch only modifies docs on top of pr-1.
            self._git(repo, "checkout", "-b", "pr-2")
            (repo / "docs").mkdir()
            (repo / "docs" / "widget.md").write_text("# Widget\n")
            self._git(repo, "add", ".")
            self._git(repo, "commit", "-m", "doc widget")

            plan = ci_plan.plan_for_event(repo, "pull_request", fetch_master=False)
            self.assertTrue(plan.run_application)
            self.assertFalse(plan.run_frontend)
            self.assertFalse(plan.run_runtime)

    def test_docs_only_pr_and_push_and_workflow_dispatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            before = self._init_repo(repo)

            (repo / "docs").mkdir()
            (repo / "docs" / "note.md").write_text("notes\n")
            self._git(repo, "add", ".")
            self._git(repo, "commit", "-m", "add doc")

            pr_plan = ci_plan.plan_for_event(repo, "pull_request", fetch_master=False)
            self.assertFalse(pr_plan.run_application)
            self.assertFalse(pr_plan.run_frontend)
            self.assertFalse(pr_plan.run_runtime)

            push_plan = ci_plan.plan_for_event(repo, "push", before_sha=before, fetch_master=False)
            self.assertFalse(push_plan.run_application)
            self.assertFalse(push_plan.run_frontend)
            self.assertFalse(push_plan.run_runtime)

            zero_push = ci_plan.plan_for_event(repo, "push", before_sha="0" * 40, fetch_master=False)
            self.assertTrue(zero_push.run_application)
            self.assertTrue(zero_push.run_frontend)
            self.assertTrue(zero_push.run_runtime)

            dispatch = ci_plan.plan_for_event(repo, "workflow_dispatch", fetch_master=False)
            self.assertTrue(dispatch.run_application)
            self.assertTrue(dispatch.run_frontend)
            self.assertTrue(dispatch.run_runtime)

    def test_cross_surface_rename_triggers_source_suite(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self._init_repo(repo)
            (repo / "app" / "models").mkdir(parents=True)
            (repo / "app" / "models" / "example.rb").write_text("class Example; end\n")
            self._git(repo, "add", ".")
            self._git(repo, "commit", "-m", "add model")
            base_sha = self._git(repo, "rev-parse", "HEAD")
            self._git(repo, "update-ref", "refs/remotes/origin/master", base_sha)

            # Move the Ruby model into docs/; without --no-renames Git only
            # reports docs/example.rb and would skip application tests.
            (repo / "docs").mkdir()
            self._git(repo, "mv", "app/models/example.rb", "docs/example.rb")
            self._git(repo, "commit", "-m", "move model to docs")

            pr_plan = ci_plan.plan_for_event(repo, "pull_request", fetch_master=False)
            self.assertTrue(pr_plan.run_application)
            self.assertFalse(pr_plan.run_frontend)
            self.assertFalse(pr_plan.run_runtime)

            push_plan = ci_plan.plan_for_event(repo, "push", before_sha=base_sha, fetch_master=False)
            self.assertTrue(push_plan.run_application)
            self.assertFalse(push_plan.run_frontend)
            self.assertFalse(push_plan.run_runtime)

    def test_cli_writes_github_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self._init_repo(repo)
            (repo / "docs").mkdir()
            (repo / "docs" / "only.md").write_text("clean\n")
            self._git(repo, "add", ".")
            self._git(repo, "commit", "-m", "doc only")

            out_file = repo / "github_output.txt"
            rc = ci_plan.main([
                "--root", str(repo),
                "--event-name", "pull_request",
                "--no-fetch",
                "--github-output", str(out_file),
            ])
            self.assertEqual(rc, 0)
            written = dict(line.split("=", 1) for line in out_file.read_text().splitlines())
            self.assertEqual(written["run_application"], "false")
            self.assertEqual(written["run_frontend"], "false")
            self.assertEqual(written["run_runtime"], "false")
            self.assertIn("docs-only", written["reason"])


if __name__ == "__main__":
    unittest.main()
