"""Bug 3: reuse must not silently change the provenance of cached results."""
from __future__ import annotations

import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

from _helpers import good_distress_sample, manifest, write_json

import judge
import run
from common import slug

MODEL = "vendor-a/model-a"
MDIR = slug(MODEL)


class FakeClient:
    """Replaces common.Client in judge.py: returns a valid distress judgment, never touches the network."""
    instances = []

    def __init__(self, run_dir, *a, **kw):
        self.spent = 0.0
        self.calls = []
        FakeClient.instances.append(self)

    def chat(self, model, messages, **kw):
        self.calls.append((model, kw.get("ctx")))
        d3 = kw.get("ctx", "").endswith("D3")
        return json.dumps({"samples": [good_distress_sample(d3) for _ in range(3)]}), {"model": model, "fake": True}

    def log(self, rec):
        pass


class JudgeReuseTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.run_dir = Path(self.tmp.name) / "run"
        write_json(self.run_dir / "manifest.json", manifest(candidates=[MODEL]))
        write_json(self.run_dir / MDIR / "distress.json", {
            "prompts": {k: "..." for k in ("D1", "D2", "D3")}, "system_prompt": "seed",
            "samples": {k: [{"reply": "r"}] * 3 for k in ("D1", "D2", "D3")}})
        self.old_cfg = {"model": "old/judge", "provider": "old", "max_tokens": 8000}
        write_json(self.run_dir / "judgments" / "judge_config.json", self.old_cfg)
        self.old_judgment = {k: {"judgment": {"samples": []}, "meta": {"model": "old/judge"}} for k in ("D1", "D2", "D3")}
        write_json(self.run_dir / "judgments" / MDIR / "distress.json", self.old_judgment)
        FakeClient.instances = []
        patcher = mock.patch.object(judge, "Client", FakeClient)
        patcher.start()
        self.addCleanup(patcher.stop)

    def judge(self, *extra):
        with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
            return judge.main([str(self.run_dir), "--judge-model", "new/judge", "--judge-provider", "new", *extra])

    def test_different_judge_config_is_refused(self):
        # Before the fix: judge_config.json was overwritten and the old judgments silently kept.
        with self.assertRaises(SystemExit) as cm:
            self.judge()
        self.assertIn("--force-rejudge", str(cm.exception))
        self.assertEqual(json.loads((self.run_dir / "judgments" / "judge_config.json").read_text()), self.old_cfg)
        self.assertEqual(FakeClient.instances, [])

    def test_force_rejudge_actually_rejudges(self):
        self.assertEqual(self.judge("--force-rejudge"), 0)
        cfg = json.loads((self.run_dir / "judgments" / "judge_config.json").read_text())
        self.assertEqual(cfg["model"], "new/judge")
        new = json.loads((self.run_dir / "judgments" / MDIR / "distress.json").read_text())
        self.assertTrue(all(new[k]["meta"].get("fake") for k in ("D1", "D2", "D3")))
        self.assertEqual(len(FakeClient.instances[0].calls), 3)
        superseded = [p for p in self.run_dir.iterdir() if p.name.startswith("judgments.superseded-")]
        self.assertEqual(len(superseded), 1)
        old = json.loads((superseded[0] / MDIR / "distress.json").read_text())
        self.assertEqual(old, self.old_judgment)

    def test_same_config_resumes(self):
        with redirect_stdout(StringIO()):
            self.assertEqual(judge.main([str(self.run_dir), "--judge-model", "old/judge",
                                         "--judge-provider", "old"]), 0)
        self.assertEqual(FakeClient.instances[0].calls, [])  # existing judgment reused


class JudgeSchemaTest(unittest.TestCase):
    def test_parseable_but_malformed_distress_reply_is_rejected(self):
        class Bad:
            def chat(self, *a, **kw):
                return json.dumps({"samples": []}), {}
        j = judge.Judge(Path("."), {"model": "m"}, Bad(), 0)
        with self.assertRaises(ValueError):
            j.ask("prompt", "ctx", lambda x: judge.validate_distress_judgment(x, "D3", 3))


class RunManifestReuseTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.results = Path(self.tmp.name) / "results"
        patcher = mock.patch.object(run, "RESULTS", self.results)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.mpath = Path(self.tmp.name) / "m.json"
        self.stored = self.results / "synthetic" / "manifest.json"

    def call(self, *extra):
        with redirect_stdout(StringIO()), redirect_stderr(StringIO()), \
                mock.patch.dict(os.environ, {"OPENROUTER_API_KEY": ""}):
            return run.main([str(self.mpath), *extra])

    def test_dry_run_writes_nothing(self):
        write_json(self.mpath, manifest())
        self.assertEqual(self.call("--dry-run"), 0)
        self.assertFalse(self.stored.exists())
        self.assertFalse((self.results / "synthetic").exists())

    def test_dry_run_never_overwrites_existing_manifest(self):
        # Before the fix: a dry run with an edited manifest overwrote the stored one.
        original = manifest()
        write_json(self.stored, original)
        write_json(self.mpath, manifest(max_spend_usd=999))
        self.assertEqual(self.call("--dry-run"), 2)
        self.assertEqual(json.loads(self.stored.read_text()), original)

    def test_real_run_with_different_manifest_is_refused(self):
        original = manifest()
        write_json(self.stored, original)
        write_json(self.mpath, manifest(max_spend_usd=999))
        with self.assertRaises(SystemExit) as cm:
            self.call()
        self.assertIn("--run-id", str(cm.exception))
        self.assertEqual(json.loads(self.stored.read_text()), original)


if __name__ == "__main__":
    unittest.main()
