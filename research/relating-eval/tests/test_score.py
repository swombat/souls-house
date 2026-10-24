"""Bug 2 (manifest-based completeness) and bug 4 (fail-closed distress gate)."""
from __future__ import annotations

import json
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path

from _helpers import good_distress, manifest, write_distress_judgment, write_json, write_judged_unit

import score
from common import slug
from personas import PERSONAS

MODEL = "vendor-a/model-a"
MDIR = slug(MODEL)
PID = PERSONAS[0]["id"]


class ScoreFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.run_dir = Path(self.tmp.name) / "run"
        (self.run_dir).mkdir()
        (self.run_dir / "calls.jsonl").write_text("")

    def score(self, m):
        write_json(self.run_dir / "manifest.json", m)
        with redirect_stdout(StringIO()):
            score.main([str(self.run_dir)])
        return json.loads((self.run_dir / "summary.json").read_text())["models"][MODEL]


class CompletenessTest(ScoreFixture):
    def test_absent_units_withhold_headline(self):
        # Four expected units (persona 0 x 4 repeats), only one exists and is judged.
        m = manifest(personas=[0], repeats={"0": 4}, candidates=[MODEL])
        write_judged_unit(self.run_dir, MDIR, f"{PID}_r0")
        write_distress_judgment(self.run_dir, MDIR, good_distress())
        r = self.score(m)
        self.assertFalse(r["complete"])
        self.assertIsNone(r["headline"])
        self.assertEqual(r["missing_units"], [f"{PID}_r1", f"{PID}_r2", f"{PID}_r3"])
        self.assertEqual(r["expected_units"], 4)

    def test_all_units_present_is_complete(self):
        m = manifest(personas=[0], repeats={"0": 2}, candidates=[MODEL])
        for r_ in range(2):
            write_judged_unit(self.run_dir, MDIR, f"{PID}_r{r_}")
        write_distress_judgment(self.run_dir, MDIR, good_distress())
        r = self.score(m)
        self.assertTrue(r["complete"])
        self.assertEqual(r["missing_units"], [])
        self.assertAlmostEqual(r["headline"], 1.0)


class DistressFailClosedTest(ScoreFixture):
    def _score_with(self, distress):
        m = manifest(personas=[0], candidates=[MODEL])
        write_judged_unit(self.run_dir, MDIR, f"{PID}_r0")
        write_distress_judgment(self.run_dir, MDIR, distress)
        return self.score(m)

    def assertUnjudged(self, r):
        self.assertIsNone(r["gates"]["distress"])
        self.assertIsNone(r["distress"]["pass"])
        self.assertTrue(r["distress"]["errors"])
        self.assertFalse(r["complete"])
        self.assertIsNone(r["headline"])

    def test_empty_samples_do_not_pass_gate(self):
        # Before the fix: all([]) passed D3's safety condition and the gate passed.
        r = self._score_with({k: {"judgment": {"samples": []}} for k in ("D1", "D2", "D3")})
        self.assertUnjudged(r)

    def test_missing_prompt_is_unjudged(self):
        d = good_distress()
        del d["D3"]
        r = self._score_with(d)
        self.assertUnjudged(r)
        self.assertIsNone(r["distress"]["prompts"]["D3"]["pass"])

    def test_wrong_sample_count_is_unjudged(self):
        d = good_distress()
        d["D2"]["judgment"]["samples"] = d["D2"]["judgment"]["samples"][:1]
        self.assertUnjudged(self._score_with(d))

    def test_wrong_field_types_are_unjudged(self):
        d = good_distress()
        d["D3"]["judgment"]["samples"][0]["safety_line"] = None
        self.assertUnjudged(self._score_with(d))
        d = good_distress()
        d["D1"]["judgment"]["samples"][1]["stays_with_them"] = "maybe"
        self.assertUnjudged(self._score_with(d))

    def test_valid_distress_still_passes_and_fails(self):
        r = self._score_with(good_distress())
        self.assertTrue(r["gates"]["distress"])
        d = good_distress()
        for s in d["D3"]["judgment"]["samples"]:
            s["safety_line"] = False
        r = self._score_with(d)
        self.assertIs(r["gates"]["distress"], False)
        self.assertEqual(r["headline"], 0.0)


if __name__ == "__main__":
    unittest.main()
