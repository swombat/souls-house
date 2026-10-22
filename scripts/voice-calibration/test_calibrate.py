"""Synthetic audits. Set VOICE_BENCHMARK to the existing frozen benchmark."""
import copy
import hashlib
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

import calibrate as c


class CalibrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scorer = c.load_scorer(Path(os.environ["VOICE_BENCHMARK"])) if os.environ.get("VOICE_BENCHMARK") else None

    def setUp(self):
        self.rows = [
            {"id": f"synthetic-{s}-{g}", "speaker_id": s, "session_group": g,
             "domain": "voip", "audio_path": f"synthetic/{s}-{g}.wav"}
            for s in ("A", "B", "D") for g in ("one", "two", "three", "four", "five")
        ]
        self.plan = self.scorer.freeze(self.rows) if self.scorer else None

    @unittest.skipUnless(os.environ.get("VOICE_BENCHMARK"), "requires the external frozen benchmark scorer")
    def test_development_excludes_test_roles_and_test_identity_cohort(self):
        selected = c.development(self.rows, self.plan, self.scorer)
        self.assertTrue(selected)
        for row in selected:
            self.assertEqual("dev", self.plan["group_roles"][row["session_group"]])
            self.assertNotEqual("unknown_test", self.plan["speaker_cohorts"][row["speaker_id"]])

    @unittest.skipUnless(os.environ.get("VOICE_BENCHMARK"), "requires the external frozen benchmark scorer")
    def test_edited_split_refused_before_any_vector_read(self):
        plan = copy.deepcopy(self.plan)
        group = next(iter(plan["group_roles"]))
        plan["group_roles"][group] = "altered"
        with self.assertRaises(ValueError):
            c.development(self.rows, plan, self.scorer)

    @unittest.skipUnless(os.environ.get("VOICE_BENCHMARK"), "requires the external frozen benchmark scorer")
    def test_source_and_content_leakage_refused(self):
        for field in ("source_identifier", "source_group_key", "source_sha256", "content_sha256"):
            rows = copy.deepcopy(self.rows)
            for row in rows:
                row[field] = "synthetic-duplicate"
            with self.assertRaises(ValueError):
                self.scorer.validate_rows(rows)

    @unittest.skipUnless(os.environ.get("VOICE_BENCHMARK"), "requires the external frozen benchmark scorer")
    def test_only_selected_development_cache_opened(self):
        selected = c.development(self.rows, self.plan, self.scorer)[:1]
        selected[0]["content_sha256"] = "synthetic-content"
        info = {"models": {"wespeaker": {"version": "synthetic", "load_ms": 1}},
                "worker_sha256": "synthetic-worker", "ffmpeg": "synthetic",
                "aggregation": "whole", "threads": 4}
        metadata = dict(audio="synthetic-content", start=0, end=None,
                        worker="synthetic-worker", model={"version": "synthetic"},
                        ffmpeg="synthetic", aggregation="whole", threads=4)
        key = hashlib.sha256(self.scorer.canonical(metadata).encode()).hexdigest()
        saved = {"audio_sha256": "synthetic-content", "start_s": 0, "end_s": None,
                 "model": info["models"]["wespeaker"],
                 "result": {"status": "ok", "embedding": [1, 0]}}
        calls = []
        def read(path):
            calls.append(path.name)
            if path.name == "run.json":
                return info
            if path.name == key + ".json":
                return saved
            raise AssertionError("Attempted unselected cache read")
        with patch.object(self.scorer, "read_json", side_effect=read):
            actual = c.cache_vectors(Path("synthetic"), selected, "wespeaker", "synthetic", self.scorer)
        self.assertEqual(2, len(calls))
        self.assertEqual({selected[0]["id"]}, set(actual))
        saved["result"]["status"] = "error"
        with patch.object(self.scorer, "read_json", side_effect=read), self.assertRaises(ValueError):
            c.cache_vectors(Path("synthetic"), selected, "wespeaker", "synthetic", self.scorer)

    def test_same_session_pairs_excluded_and_pairing_fixed(self):
        vectors = {r["id"]: [1, 0] if r["speaker_id"] == "A" else [0, 1] for r in self.rows}
        obs = c.observations(self.rows, vectors)
        self.assertEqual(30, len(obs["positive"]))
        self.assertEqual(60, len(obs["negative"]))
        self.assertEqual(len(obs["wrong"]), len(obs["correct"]))
        reversed_obs = c.observations(list(reversed(self.rows)), vectors)
        for key in obs:
            self.assertEqual(sorted(obs[key]), sorted(reversed_obs[key]))

    def test_threshold_blocks_and_upward_rounding(self):
        self.assertEqual(.504, c.choose([.5031, .4, .5031], 0))
        self.assertEqual(.504, c.choose([.5031, .4, .5031], 1))
        self.assertEqual(.15, c.choose([-.1, -.2], 0, floor=.15))

    def test_conservative_joint_and_split_policy(self):
        old = dict(negative=[.6, .2], positive=[.8, .7],
                   wrong=[(.6, .2), (.2, -.2)], correct=[(.8, .1), (.7, .5)])
        new = dict(negative=[.7, .3], positive=[.9, .8],
                   wrong=[(.7, .4), (.3, -.1)], correct=[(.9, .2), (.8, .6)])
        result = c.calibrate(old, new)
        for key in ("impostor_pairs", "wrong_margin_only", "wrong_joint", "genuine_split_pairs"):
            self.assertLessEqual(result["wespeaker"][key]["accepted"], result["ecapa"][key]["accepted"])
        self.assertGreaterEqual(result["constants"]["split_threshold"], result["constants"]["match_threshold"])
        self.assertGreaterEqual(result["constants"]["match_threshold"], .55)
        self.assertGreaterEqual(result["constants"]["match_margin"], .15)

    def test_absolute_floor_preserved_despite_zero_impostor_errors(self):
        obs = dict(negative=[.3, .4], positive=[.53, .7, .8],
                   wrong=[(.3, -.23)], correct=[(.53, .23)])
        result = c.calibrate(obs, obs)
        self.assertEqual(.55, result["constants"]["match_threshold"])
        self.assertEqual(2, result["wespeaker"]["genuine_pairs"]["accepted"])

    def test_insufficient_positive_support_refused(self):
        with self.assertRaises(ValueError):
            c.observations(self.rows[:1], {self.rows[0]["id"]: [1, 0]})

    def test_unpaired_engine_denominators_refused(self):
        old = dict(negative=[.2], positive=[.8],
                   wrong=[(.2, -.6)], correct=[(.8, .6)])
        new = copy.deepcopy(old)
        new["negative"].append(.3)
        with self.assertRaises(ValueError):
            c.calibrate(old, new)


if __name__ == "__main__":
    unittest.main()
