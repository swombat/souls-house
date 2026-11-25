"""Offline provenance and coverage contracts for reusable PR CI receipts."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "ci_tree_receipt", ROOT / ".github/scripts/tree_receipt.py"
)
receipt_module = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = receipt_module
SPEC.loader.exec_module(receipt_module)

REPOSITORY = "souls-house/souls-house"
MASTER, BASE, TREE, HEAD = (character * 40 for character in "abcd")
MERGED = "2026-11-25T12:00:00Z"
FINISHED = "2026-11-25T11:59:00Z"
MARKER = f"CI v1 #42 {TREE} {BASE}"
APPLICATION = [
    f"{suite} ({shard}/{total})"
    for suite, total in (("rails", 4), ("e2e", 10), ("components", 1))
    for shard in range(1, total + 1)
]


class CiTreeReceiptTest(unittest.TestCase):
    def setUp(self):
        self.pr = {
            "number": 42,
            "merged_at": MERGED,
            "merge_commit_sha": MASTER,
            "base": {"ref": "master", "sha": BASE,
                     "repo": {"full_name": REPOSITORY}},
            "head": {"sha": HEAD, "repo": {"full_name": REPOSITORY}},
        }
        self.run = {
            "id": 123,
            "run_attempt": 1,
            "path": ".github/workflows/ci.yml",
            "event": "pull_request",
            "head_sha": HEAD,
            "repository": {"full_name": REPOSITORY},
            "head_repository": {"full_name": REPOSITORY},
            "status": "completed",
            "conclusion": "success",
            # GitHub empties this list after merge, even for same-repo PRs.
            "pull_requests": [],
        }
        self.jobs = []
        self.add_jobs(MARKER, "CI result", "Python runtime tests")
        self.calls = []

    def add_jobs(self, *names):
        for name in names:
            self.jobs.append({
                "id": 1000 + len(self.jobs),
                "name": name,
                "run_id": 123,
                "run_attempt": 1,
                "status": "completed",
                "conclusion": "success",
                "started_at": "2026-11-25T11:50:00Z",
                "completed_at": FINISHED,
            })

    def api(self, path):
        self.calls.append(path)
        responses = {
            f"/commits/{MASTER}/pulls?per_page=20": [self.pr],
            f"/actions/workflows/ci.yml/runs?event=pull_request&head_sha={HEAD}&per_page=10":
                {"total_count": 1, "workflow_runs": [self.run]},
            "/actions/runs/123/attempts/1/jobs?per_page=100":
                {"total_count": len(self.jobs), "jobs": self.jobs},
        }
        self.assertIn(path, responses, "Unexpected API request (tests never use network)")
        return copy.deepcopy(responses[path])

    def find(self):
        return receipt_module.find_receipt(
            self.api, REPOSITORY, MASTER, BASE, TREE
        )

    def assert_suites(self, expected):
        receipt = self.find()
        self.assertIsInstance(receipt, receipt_module.Receipt)
        self.assertEqual(receipt.run_id, 123)
        self.assertEqual(receipt.attempt, 1)
        self.assertEqual(receipt.suites, frozenset(expected))
        self.assertIsInstance(receipt.suites, frozenset)

    def test_runtime_only_is_a_valid_partial_receipt(self):
        self.assert_suites({"runtime"})
        self.assertEqual(len(self.calls), 3)

    def test_full_coverage(self):
        self.add_jobs("Frontend unit tests", *APPLICATION)
        self.assert_suites({"runtime", "frontend", "application"})

    def test_job_names_match_the_trusted_workflow(self):
        jobs = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text())["jobs"]
        rows = jobs["application"]["strategy"]["matrix"]["include"]
        expected = {
            "application": {f"{r['suite']} ({r['shard']}/{r['total']})" for r in rows},
            **{key: {jobs[key]["name"]} for key in ("frontend", "runtime")},
        }
        self.assertEqual(receipt_module.SUITE_JOBS, expected)

    def test_a_receipt_must_cover_the_entire_independent_master_plan(self):
        for required, qualifies in (({"runtime"}, True), ({"runtime", "frontend"}, False)):
            with self.subTest(required=required):
                receipt = receipt_module.find_receipt(
                    self.api, REPOSITORY, MASTER, BASE, TREE, required
                )
                self.assertEqual(receipt is not None, qualifies)

    def test_each_missing_application_shard_withholds_application(self):
        baseline = copy.deepcopy(self.jobs)
        for missing in APPLICATION:
            with self.subTest(missing=missing):
                self.jobs = copy.deepcopy(baseline)
                self.add_jobs(*(name for name in APPLICATION if name != missing))
                self.assert_suites({"runtime"})

    def test_wrong_pr_tree_or_base_cannot_authorize_reuse(self):
        for marker in (
            f"CI v1 #43 {TREE} {BASE}",
            f"CI v1 #42 {'e' * 40} {BASE}",
            f"CI v1 #42 {TREE} {'e' * 40}",
            MARKER + " extra",
        ):
            with self.subTest(marker=marker):
                self.jobs[0]["name"] = marker
                self.assertIsNone(self.find())

    def test_run_provenance_must_match(self):
        cases = (
            ("path", ".github/workflows/not-ci.yml"),
            ("event", "push"),
            ("event", "pull_request_target"),
            ("head_sha", "e" * 40),
            ("repository", {"full_name": "other/repo"}),
            ("head_repository", {"full_name": "fork/repo"}),
            ("status", "in_progress"),
            ("conclusion", "failure"),
            ("run_attempt", 2),
        )
        baseline = copy.deepcopy(self.run)
        for key, value in cases:
            with self.subTest(field=key, value=value):
                self.run = copy.deepcopy(baseline)
                self.run[key] = value
                self.assertIsNone(self.find())

    def test_only_a_direct_same_repository_merge_into_master_is_trusted(self):
        cases = (
            ("merged_at", None),
            ("merged_at", ""),
            ("merge_commit_sha", "e" * 40),
            ("base", {"ref": "release", "sha": BASE,
                      "repo": {"full_name": REPOSITORY}}),
            ("base", {"ref": "master", "sha": BASE,
                      "repo": {"full_name": "other/repo"}}),
            ("head", {"sha": HEAD, "repo": {"full_name": "fork/repo"}}),
        )
        baseline = copy.deepcopy(self.pr)
        for key, value in cases:
            with self.subTest(field=key, value=value):
                self.pr = copy.deepcopy(baseline)
                self.pr[key] = value
                self.assertIsNone(self.find())

    def test_receipt_and_result_jobs_require_successful_bound_first_attempt(self):
        baseline = copy.deepcopy(self.jobs)
        for index in (0, 1):
            for key, value in (
                ("status", "in_progress"),
                ("conclusion", "skipped"),
                ("conclusion", "failure"),
                ("run_id", 999),
                ("run_attempt", 2),
                ("completed_at", None),
                ("completed_at", "2026-11-25T12:00:01Z"),
            ):
                with self.subTest(job=baseline[index]["name"], field=key, value=value):
                    self.jobs = copy.deepcopy(baseline)
                    self.jobs[index][key] = value
                    self.assertIsNone(self.find())

    def test_receipt_and_result_must_both_exist(self):
        baseline = copy.deepcopy(self.jobs)
        for index in (0, 1):
            with self.subTest(missing=baseline[index]["name"]):
                self.jobs = copy.deepcopy(baseline)
                del self.jobs[index]
                self.assertIsNone(self.find())

    def test_completion_at_merge_time_is_accepted(self):
        self.jobs[0]["completed_at"] = MERGED
        self.jobs[1]["completed_at"] = MERGED
        self.assert_suites({"runtime"})

    def test_marker_not_current_pr_base_sha_binds_tested_base(self):
        self.pr["base"]["sha"] = "e" * 40
        self.assert_suites({"runtime"})

    def test_untrusted_suite_job_cannot_supply_coverage(self):
        baseline = copy.deepcopy(self.jobs)
        for key, value in (
            ("status", "in_progress"), ("conclusion", "skipped"),
            ("run_id", 999), ("run_attempt", 2),
        ):
            with self.subTest(field=key, value=value):
                self.jobs = copy.deepcopy(baseline)
                self.jobs[2][key] = value
                receipt = self.find()
                self.assertTrue(receipt is None or "runtime" not in receipt.suites)

    def test_multiple_push_commits_or_changed_trust_code_never_query_github(self):
        event = {"ref": "refs/heads/master", "forced": False, "before": BASE, "after": MASTER}
        cases = (
            (event, HEAD, ""),
            (event, BASE, ".github/workflows/ci.yml"),
            (event, BASE, "scripts/ci_plan.py"),
            ({**event, "forced": True}, BASE, ""),
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "push.json"
            for payload, parent, changed in cases:
                with self.subTest(payload=payload, parent=parent, changed=changed):
                    path.write_text(json.dumps(payload))
                    git_calls = {
                        ("rev-parse", "HEAD"): MASTER,
                        ("rev-parse", "HEAD^1"): parent,
                        ("diff", "--name-only", BASE, MASTER, "--", ".github/", "scripts/ci_plan.py"): changed,
                    }
                    with (
                        patch.dict(os.environ, {"GITHUB_EVENT_PATH": str(path), "GITHUB_SHA": MASTER}),
                        patch.object(receipt_module, "git", side_effect=lambda *a: git_calls[a]),
                        patch.object(receipt_module, "build_opener") as opener,
                    ):
                        self.assertIsNone(receipt_module.from_push())
                        opener.assert_not_called()


if __name__ == "__main__":
    unittest.main()
