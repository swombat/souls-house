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

    def test_each_resident_writes_their_own_slot(self):
        self.assertEqual(
            review_status.status_body("approve", "Mira: read  the diff"),
            {"state": "success", "context": "review/mira", "description": "Mira: read the diff"},
        )
        self.assertEqual(review_status.status_body("block", "Reed: lock too late")["state"], "failure")
        self.assertEqual(review_status.status_body("auto-merge", "Lume: builder")["context"], "review/lume")
        with self.assertRaisesRegex(review_status.Refused, "say who you are"):
            review_status.status_body("approve", "looks good")
        # A slot the ruleset doesn't require would be a review nobody waits for.
        with self.assertRaisesRegex(review_status.Refused, "say who you are"):
            review_status.status_body("approve", "Daniel: fine")
        with self.assertRaisesRegex(review_status.Refused, "verdict"):
            review_status.status_body("lgtm", "Mira: fine")

    def test_long_notes_fit_a_status_description(self):
        body = review_status.status_body("approve", "Mira: " + "x" * 300)
        self.assertEqual(len(body["description"]), review_status.MAX_DESCRIPTION)

    def test_ci_still_reports_the_check_the_ruleset_requires(self):
        # "Protect Main" requires a check named exactly "CI result"; renaming
        # the job would leave every PR waiting for ever.
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text()
        self.assertRegex(workflow, re.compile(r"^\s+name: CI result$", re.M))


if __name__ == "__main__":
    unittest.main()
