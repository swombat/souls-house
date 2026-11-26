"""The review status is the merge gate, so its refusals are the contract."""
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
# A .pyc under scripts/ would trip the Rails identity-leak scan of that tree.
sys.dont_write_bytecode = True
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

    def test_builder_plus_one_review_is_a_quorum(self):
        state, description = review_status.quorum([
            {"context": "review/reed", "state": "success"},
            {"context": "review/mira", "state": "success"},
        ])
        self.assertEqual(state, "success")
        self.assertIn("mira + reed", description)

    def test_one_slot_alone_waits(self):
        self.assertEqual(review_status.quorum([{"context": "review/lume", "state": "success"}])[0], "pending")
        self.assertEqual(review_status.quorum([])[0], "pending")

    def test_a_block_holds_against_any_number_of_approvals(self):
        state, description = review_status.quorum([
            {"context": "review/lume", "state": "success"},
            {"context": "review/mira", "state": "success"},
            {"context": "review/reed", "state": "failure"},
        ])
        self.assertEqual(state, "failure")
        self.assertIn("reed", description)

    def test_only_resident_slots_count(self):
        # The quorum's own earlier verdict, CI, or an unknown name must not
        # stand in for a second resident.
        state, _ = review_status.quorum([
            {"context": "review/lume", "state": "success"},
            {"context": "review/quorum", "state": "success"},
            {"context": "review/daniel", "state": "success"},
            {"context": "CI result", "state": "success"},
        ])
        self.assertEqual(state, "pending")

    def test_the_newest_status_for_a_slot_wins(self):
        # The combined-status API lists newest first; an approval after a
        # block by the same reviewer lifts it.
        state, _ = review_status.quorum([
            {"context": "review/mira", "state": "success"},
            {"context": "review/mira", "state": "failure"},
            {"context": "review/lume", "state": "success"},
        ])
        self.assertEqual(state, "success")

    def test_the_quorum_workflow_runs_on_review_statuses_only(self):
        workflow = (ROOT / ".github" / "workflows" / "review-quorum.yml").read_text()
        self.assertRegex(workflow, re.compile(r"^on:\n  status:", re.M))
        self.assertIn("github.event.context != 'review/quorum'", workflow)
        self.assertIn("scripts/review-status quorum", workflow)
        self.assertEqual(review_status.QUORUM_CONTEXT, "review/quorum")


if __name__ == "__main__":
    unittest.main()
