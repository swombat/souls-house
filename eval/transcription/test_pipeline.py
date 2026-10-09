import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).parent


def make_corpus(root):
    rows = [
        {"sample_id": "good1", "speaker": "d@x", "discarded": False, "audio_path": "audio/good1.webm",
         "sent_text": "let us review the pull request for the field recordings this afternoon please", "context": []},
        {"sample_id": "bad1", "speaker": "d@x", "discarded": False, "audio_path": "audio/bad1.webm",
         "sent_text": "okay so we can merge this one now and deploy it after lunch today", "context": [{"role": "assistant", "content": "Ready to merge?"}]},
        {"sample_id": "gone1", "speaker": "p@x", "discarded": True, "audio_path": "audio/gone1.webm",
         "sent_text": "the soul is a field not a ladder and we hold it together", "context": []},
    ]
    (root / "manifest.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    runs = {
        "scribe_v2": {"good1": rows[0]["sent_text"], "bad1": "okay so we came urge this one now and the ploy it after lunch today",
                      "gone1": rows[2]["sent_text"]},
        "other": {"good1": rows[0]["sent_text"], "bad1": rows[1]["sent_text"], "gone1": "the soul is a field not a ladder and we hold it together"},
    }
    for provider, texts in runs.items():
        (root / "runs" / provider).mkdir(parents=True)
        for sid, text in texts.items():
            (root / "runs" / provider / f"{sid}.json").write_text(json.dumps({"text": text}))


class PipelineTest(unittest.TestCase):
    def test_report_and_packets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            make_corpus(root)
            out = subprocess.run([sys.executable, HERE / "report.py", root, "--min-words", "5"],
                                 capture_output=True, text=True, check=True).stdout
            self.assertIn("| scribe_v2 |", out)
            gold = [json.loads(l) for l in (root / "gold.jsonl").read_text().splitlines()]
            labels = {g["sample_id"]: g["label"] for g in gold}
            self.assertEqual({"good1": "good", "bad1": "bad", "gone1": "bad"}, labels)

            subprocess.run([sys.executable, HERE / "judge_packets.py", root], check=True, capture_output=True)
            packets = sorted(p.stem for p in (root / "packets").iterdir())
            self.assertEqual(["bad1"], packets)  # only bad1 has disagreement
            self.assertIn("Ready to merge?", (root / "packets" / "bad1.md").read_text())


if __name__ == "__main__":
    unittest.main()
