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
        self.assertEqual(len(matrix) + len(self.jobs) - 1, 9)
        for suite, total in (("rails", 2), ("e2e", 3), ("components", 1)):
            rows = [row for row in matrix if row["suite"] == suite]
            self.assertEqual(sorted(row["shard"] for row in rows), list(range(1, total + 1)))
            self.assertTrue(all(row["total"] == total for row in rows))
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        self.assertTrue(all("permissions" not in job for job in self.jobs.values()))

    def test_public_digest_and_container_network(self):
        application = self.jobs["application"]
        self.assertRegex(application["container"]["image"], r"^ghcr\.io/[^@]+@sha256:[0-9a-f]{64}$")
        self.assertEqual(application["container"]["options"], "--ipc=host")
        self.assertEqual(application["env"]["PGHOST"], "postgres")
        self.assertEqual(application["env"]["PARALLEL_WORKERS"], "4")
        self.assertEqual(application["env"]["BUNDLE_FROZEN"], "true")
        self.assertNotIn("ports", application["services"]["postgres"])

    def test_all_coverage_entrypoints_and_unique_artifacts(self):
        steps = {step.get("name"): step for step in self.jobs["application"]["steps"] if "name" in step}
        self.assertIn("ruby scripts/run-rails-shard.rb", steps["Rails tests"]["run"])
        self.assertIn("matrix.shard == 1", steps["Rails system tests"]["if"])
        browser = steps["Browser end-to-end tests"]["run"]
        self.assertIn("--no-deps", browser)
        self.assertIn("--workers=1", browser)
        self.assertIn("--shard=${{ matrix.shard }}/${{ matrix.total }}", browser)
        self.assertEqual(steps["Browser component tests"]["run"], "bun run test:ct")
        self.assertIn("matrix.shard", steps["Preserve browser failure reports"]["with"]["name"])
        self.assertNotIn("matrix.suite != 'rails'", steps["Prepare test database"]["if"])
        dockerfile = (ROOT / ".github/ci/Dockerfile").read_text()
        bases = re.findall(r"^FROM (.+)$", dockerfile, re.M)
        self.assertEqual(len(bases), 3)
        self.assertTrue(all(re.search(r"@sha256:[0-9a-f]{64}(?: AS \w+)?$", base) for base in bases))

    def test_aggregate_rejects_failure_cancel_and_skip(self):
        result = self.jobs["result"]
        self.assertEqual(result["if"], "always()")
        self.assertEqual(set(result["needs"]), {"application", "frontend", "runtime"})
        lines = result["steps"][0]["run"].splitlines()
        self.assertEqual(lines[0], "python3 - <<'PY'")
        self.assertEqual(lines[-1], "PY")
        script = "\n".join(lines[1:-1])
        for state in ("success", "failure", "cancelled", "skipped"):
            results = {name: {"result": "success"} for name in result["needs"]}
            results["application"]["result"] = state
            process = subprocess.run(
                [sys.executable, "-c", script],
                env={"PATH": os.environ.get("PATH", ""), "RESULTS": json.dumps(results)},
                capture_output=True,
                text=True,
            )
            self.assertEqual(process.returncode == 0, state == "success", process.stderr)


if __name__ == "__main__":
    unittest.main()
