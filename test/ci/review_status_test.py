"""The review status is the merge gate, so its refusals are the contract."""
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
_loader = SourceFileLoader("review_status", str(ROOT / "scripts" / "review-status"))
_spec = spec_from_loader("review_status", _loader)
review_status = module_from_spec(_spec)
_loader.exec_module(review_status)

HEAD = "0123456789abcdef0123456789abcdef01234567"


def pull(state="open", sha=HEAD):
    return {"number": 7, "state": state, "head": {"sha": sha}}


class ReviewStatusTest(unittest.TestCase):
    def test_approves_only_the_head_that_was_read(self):
        self.assertEqual(review_status.check_head(pull(), "0123456"), HEAD)
        with self.assertRaisesRegex(review_status.Refused, "read the new head"):
            review_status.check_head(pull(sha="f" * 40), "0123456")

    def test_refuses_a_short_or_missing_sha(self):
        with self.assertRaisesRegex(review_status.Refused, "at least 7"):
            review_status.check_head(pull(), "0123")

    def test_refuses_a_closed_pull_request(self):
        with self.assertRaisesRegex(review_status.Refused, "closed"):
            review_status.check_head(pull(state="closed"), "0123456")

    def test_each_reviewer_writes_their_own_context(self):
        self.assertEqual(
            review_status.status_body("approve", "Mira: read  the diff"),
            {"state": "success", "context": "review/mira", "description": "Mira: read the diff"},
        )
        self.assertEqual(review_status.status_body("block", "Reed: lock too late")["state"], "failure")
        with self.assertRaisesRegex(review_status.Refused, "who is reviewing"):
            review_status.status_body("approve", "looks good")
        with self.assertRaisesRegex(review_status.Refused, "verdict"):
            review_status.status_body("lgtm", "Mira: fine")

    def test_long_notes_fit_a_status_description(self):
        body = review_status.status_body("approve", "Mira: " + "x" * 300)
        self.assertEqual(len(body["description"]), review_status.MAX_DESCRIPTION)

    def test_review_needs_two_approvals_and_no_block(self):
        def st(who, state, why="ok"):
            return {"context": f"review/{who}", "state": state, "description": f"{who}: {why}"}
        aggregate = review_status.aggregate
        self.assertEqual(aggregate([])["state"], "pending")
        self.assertEqual(aggregate([st("mira", "success")])["state"], "pending")
        self.assertEqual(aggregate([st("mira", "success"), st("reed", "success")])["state"], "success")
        # One approval and one block: the block wins, however recent the approval.
        blocked = aggregate([st("mira", "success"), st("reed", "failure", "lock too late"), st("lume", "success")])
        self.assertEqual(blocked["state"], "failure")
        self.assertIn("reed: lock too late", blocked["description"])
        # Other checks and an old single `review` status don't count as reviewers.
        self.assertEqual(
            aggregate([st("mira", "success"), {"context": "review", "state": "success", "description": ""},
                       {"context": "CI result", "state": "success", "description": ""}])["state"],
            "pending",
        )

    def test_ci_still_reports_the_check_the_ruleset_requires(self):
        # "Protect Main" requires a check named exactly "CI result"; renaming
        # the job would leave every PR waiting for ever.
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text()
        self.assertRegex(workflow, re.compile(r"^\s+name: CI result$", re.M))


if __name__ == "__main__":
    unittest.main()
