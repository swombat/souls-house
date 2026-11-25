"""Structural and executable contracts for the full-suite result."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]


class CiWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text())
        cls.jobs = cls.workflow["jobs"]

    def test_job_budget_and_partitions(self):
        matrix = self.jobs["application"]["strategy"]["matrix"]["include"]
        self.assertEqual(len(matrix) + len(self.jobs) - 1, 20)
        plan = self.jobs["plan"]
        for key in ("run_application", "run_frontend", "run_runtime"):
            self.assertIn(key, plan["outputs"])
        for suite in ("application", "frontend", "runtime"):
            self.assertEqual(self.jobs[suite]["needs"], ["plan"])
            self.assertEqual(
                self.jobs[suite]["if"],
                f"needs.plan.outputs.run_{suite} == 'true'",
            )
        for suite, total in (("rails", 4), ("e2e", 10), ("components", 1)):
            rows = [row for row in matrix if row["suite"] == suite]
            self.assertEqual(sorted(row["shard"] for row in rows), list(range(1, total + 1)))
            self.assertTrue(all(row["total"] == total for row in rows))
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        self.assertEqual(plan["permissions"], {
            "contents": "read", "actions": "read", "pull-requests": "read",
        })
        self.assertTrue(all("permissions" not in job for key, job in self.jobs.items() if key != "plan"))

    def test_receipt_is_pr_only_and_all_checkouts_pin_the_event_sha(self):
        for key in ("plan", "application", "frontend", "runtime"):
            checkout, = (step for step in self.jobs[key]["steps"] if
                         step.get("uses", "").startswith("actions/checkout@"))
            self.assertEqual(checkout["with"]["ref"], "${{ github.sha }}")
            self.assertEqual(checkout["with"]["persist-credentials"], False)
        self.assertEqual(self.jobs["receipt"]["needs"], ["plan"])
        self.assertIn("github.event_name == 'pull_request'", self.jobs["receipt"]["if"])
        lookup, = (step for step in self.jobs["plan"]["steps"] if step.get("id") == "reuse")
        self.assertEqual(lookup["if"], "github.event_name == 'push' && github.ref == 'refs/heads/master'")

    def test_public_digest_and_container_network(self):
        application = self.jobs["application"]
        self.assertRegex(application["container"]["image"], r"^ghcr\.io/[^@]+@sha256:[0-9a-f]{64}$")
        self.assertEqual(application["container"]["options"], "--ipc=host")
        self.assertEqual(application["env"]["PGHOST"], "postgres")
        self.assertEqual(application["env"]["PARALLEL_WORKERS"], "4")
        self.assertEqual(application["env"]["BUNDLE_FROZEN"], "true")
        self.assertNotIn("ports", application["services"]["postgres"])
        postgres = application["services"]["postgres"]
        self.assertRegex(
            postgres["image"],
            r"^mirror\.gcr\.io/library/postgres@sha256:[0-9a-f]{64}$",
        )
        self.assertNotIn("credentials", postgres)
        workflow_text = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertNotIn("public.ecr.aws", workflow_text)
        self.assertNotRegex(postgres["image"], r"public\.ecr\.aws|docker\.io")

    def test_all_coverage_entrypoints_and_unique_artifacts(self):
        steps = {step.get("name"): step for step in self.jobs["application"]["steps"] if "name" in step}
        self.assertIn("ruby scripts/run-rails-shard.rb", steps["Rails tests"]["run"])
        self.assertIn("matrix.shard == 1", steps["Rails system tests"]["if"])
        browser = steps["Browser end-to-end tests"]["run"]
        self.assertIn("--no-deps", browser)
        self.assertIn("--workers=1", browser)
        self.assertIn("files=$(node scripts/e2e-shard.mjs ${{ matrix.shard }} ${{ matrix.total }})", browser)
        self.assertIn("$files", browser)
        self.assertNotIn("--shard=", browser)
        self.assertEqual(steps["Browser component tests"]["run"], "bun run test:ct")
        self.assertIn("matrix.shard", steps["Preserve browser failure reports"]["with"]["name"])
        self.assertNotIn("matrix.suite != 'rails'", steps["Prepare test database"]["if"])
        dockerfile = (ROOT / ".github/ci/Dockerfile").read_text()
        bases = re.findall(r"^FROM (.+)$", dockerfile, re.M)
        self.assertEqual(len(bases), 3)
        self.assertTrue(all(re.search(r"@sha256:[0-9a-f]{64}(?: AS \w+)?$", base) for base in bases))

    def test_asset_build_is_cached_on_every_input_and_reused_by_every_suite(self):
        steps = {step.get("name"): step for step in self.jobs["application"]["steps"] if "name" in step}
        cache = steps["Restore the test asset build"]
        self.assertNotIn("if", cache)
        self.assertEqual(cache["with"]["path"].split(), ["public/vite-test", "tmp/cache/vite"])
        key = cache["with"]["key"]
        self.assertNotIn("restore-keys", cache["with"])
        for build_input in ("app/frontend/**", "app/views/**", "app/helpers/**", "config/vite.json",
                            "vite.config.js", "package.json", "bun.lock", ".github/ci/Dockerfile"):
            self.assertIn(f"'{build_input}'", key)
        names = [step.get("name") for step in self.jobs["application"]["steps"]]
        self.assertLess(names.index("Restore the test asset build"), names.index("Build test assets"))
        # vite_ruby's digest decides whether the restored build is current, so it
        # has to see the same inputs, and the browser backend must not force a rebuild.
        vite = yaml.safe_load((ROOT / "config/vite.json").read_text())
        self.assertEqual(vite["all"]["watchAdditionalPaths"], ["app/views/**/*", "app/helpers/**/*", "bun.lock"])
        self.assertNotIn("--force", (ROOT / "playwright/run-backend.rb").read_text())

    def test_aggregate_rejects_failure_cancel_and_skip(self):
        result = self.jobs["result"]
        self.assertEqual(result["name"], "CI result")
        self.assertEqual(result["if"], "always()")
        self.assertEqual(set(result["needs"]), {"plan", "receipt", "application", "frontend", "runtime"})
        lines = result["steps"][0]["run"].splitlines()
        self.assertEqual(lines[0], "python3 - <<'PY'")
        self.assertEqual(lines[-1], "PY")
        script = "\n".join(lines[1:-1])

        def run_gate(results):
            results.setdefault("receipt", {"result": "skipped"})
            return subprocess.run(
                [sys.executable, "-c", script],
                env={"PATH": os.environ.get("PATH", ""), "RESULTS": json.dumps(results)},
                capture_output=True,
                text=True,
            )

        for state in ("success", "failure", "cancelled", "skipped"):
            results = {
                "plan": {"result": "success", "outputs": {
                    "tested_tree": "a" * 40, "run_application": "true",
                    "run_frontend": "true", "run_runtime": "true",
                }},
                "receipt": {"result": state},
                **{suite: {"result": "success"} for suite in ("application", "frontend", "runtime")},
            }
            process = run_gate(results)
            self.assertEqual(process.returncode == 0, state == "success", process.stderr)

        # Planned suites must succeed; failure, cancel, and unexpected skip fail.
        for state in ("success", "failure", "cancelled", "skipped"):
            results = {
                "plan": {
                    "result": "success",
                    "outputs": {
                        "run_application": "true",
                        "run_frontend": "true",
                        "run_runtime": "true",
                    },
                },
                "application": {"result": state},
                "frontend": {"result": "success"},
                "runtime": {"result": "success"},
            }
            process = run_gate(results)
            self.assertEqual(process.returncode == 0, state == "success", process.stderr)

        # Suites explicitly skipped by plan must report skipped (never failure/cancelled/success).
        for state in ("skipped", "success", "failure", "cancelled"):
            results = {
                "plan": {
                    "result": "success",
                    "outputs": {
                        "run_application": "true",
                        "run_frontend": "false",
                        "run_runtime": "false",
                    },
                },
                "application": {"result": "success"},
                "frontend": {"result": state},
                "runtime": {"result": "skipped"},
            }
            process = run_gate(results)
            self.assertEqual(process.returncode == 0, state == "skipped", process.stderr)

        # Docs-only / all-skipped passes when plan succeeds with all flags 'false'.
        docs_only = {
            "plan": {
                "result": "success",
                "outputs": {
                    "run_application": "false",
                    "run_frontend": "false",
                    "run_runtime": "false",
                },
            },
            "application": {"result": "skipped"},
            "frontend": {"result": "skipped"},
            "runtime": {"result": "skipped"},
        }
        self.assertEqual(run_gate(docs_only).returncode, 0)

        # A failed or missing plan fails closed even if all suites were skipped.
        failed_plan = dict(docs_only, plan={"result": "failure", "outputs": docs_only["plan"]["outputs"]})
        self.assertNotEqual(run_gate(failed_plan).returncode, 0)

        # Missing/invalid plan flag fails closed.
        missing_flag = {
            "plan": {
                "result": "success",
                "outputs": {"run_application": "true", "run_frontend": "true"},
            },
            "application": {"result": "success"},
            "frontend": {"result": "success"},
            "runtime": {"result": "skipped"},
        }
        self.assertNotEqual(run_gate(missing_flag).returncode, 0)


if __name__ == "__main__":
    unittest.main()
