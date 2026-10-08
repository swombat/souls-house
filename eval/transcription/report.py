"""Score cached runs against references and pick the gold set.

    python3 report.py CORPUS_DIR [--good 30 --bad 70]

Reference for each sample, in order of preference:
  1. CORPUS_DIR/references/<sample_id>.txt  (adjudicated or hand-checked)
  2. the text the speaker actually sent

"edit rate" is WER between a fresh scribe_v2 run and the sent text: how much
the speaker had to change. It approximates the pre-edit transcript, since the
original raw text was never stored. Discarded messages are flagged separately,
because their sent text is often the bad transcript itself, not a correction.

Writes scores.csv, gold.jsonl and report.md into CORPUS_DIR.
"""
import argparse
import csv
import json
import pathlib
import statistics

from textnorm import wer
from transcribe import load_manifest

BASELINE = "scribe_v2"


def load_run(corpus, provider, sample_id):
    path = corpus / "runs" / provider / f"{sample_id}.json"
    if not path.exists():
        return None
    data = json.loads(path.read_text())
    return None if "error" in data else data


def reference_for(corpus, row):
    adjudicated = corpus / "references" / f"{row['sample_id']}.txt"
    if adjudicated.exists():
        return adjudicated.read_text().strip(), "adjudicated"
    return row["sent_text"], "sent"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus", type=pathlib.Path)
    ap.add_argument("--good", type=int, default=30)
    ap.add_argument("--bad", type=int, default=70)
    ap.add_argument("--min-words", type=int, default=8)
    args = ap.parse_args()
    corpus = args.corpus

    rows = load_manifest(corpus)
    providers = sorted(p.name for p in (corpus / "runs").iterdir() if p.is_dir()) if (corpus / "runs").exists() else []
    scored = []
    for row in rows:
        ref, ref_kind = reference_for(corpus, row)
        entry = {"sample_id": row["sample_id"], "speaker": row["speaker"], "discarded": row["discarded"],
                 "ref_kind": ref_kind, "ref_words": wer(ref, "")["ref_words"]}
        base = load_run(corpus, BASELINE, row["sample_id"])
        entry["edit_rate"] = wer(row["sent_text"], base["text"])["wer"] if base else None
        entry["duration_s"] = base.get("duration_s") if base else None
        for p in providers:
            run = load_run(corpus, p, row["sample_id"])
            entry[f"wer:{p}"] = wer(ref, run["text"])["wer"] if run else None
        scored.append(entry)

    cols = list(scored[0].keys()) if scored else []
    with open(corpus / "scores.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(scored)

    usable = [s for s in scored if s["edit_rate"] is not None and s["ref_words"] >= args.min_words]
    bad = sorted([s for s in usable if s["discarded"] or s["edit_rate"] > 0.05],
                 key=lambda s: (not s["discarded"], -s["edit_rate"]))[: args.bad]
    good = sorted([s for s in usable if not s["discarded"] and s["edit_rate"] <= 0.02],
                  key=lambda s: -s["ref_words"])[: args.good]
    with open(corpus / "gold.jsonl", "w") as f:
        for label, group in (("good", good), ("bad", bad)):
            for s in group:
                f.write(json.dumps({"sample_id": s["sample_id"], "label": label}) + "\n")

    lines = ["# Transcription eval report", "",
             f"Samples: {len(scored)} ({sum(s['discarded'] for s in scored)} discarded). "
             f"With a {BASELINE} rerun: {sum(s['edit_rate'] is not None for s in scored)}.", ""]
    rates = [s["edit_rate"] for s in usable]
    if rates:
        lines += [f"Edit rate ({BASELINE} rerun vs sent text), {len(rates)} samples of ≥{args.min_words} words: "
                  f"median {statistics.median(rates):.1%}, mean {statistics.mean(rates):.1%}, "
                  f"untouched (≤2%) {sum(r <= 0.02 for r in rates)}, heavily edited (>20%) {sum(r > 0.2 for r in rates)}.", ""]
    lines += ["| provider | samples | median WER | mean WER | WER on gold-bad | WER on gold-good |", "|---|---|---|---|---|---|"]
    gold_ids = {s["sample_id"]: lbl for lbl, grp in (("good", good), ("bad", bad)) for s in grp}
    for p in providers:
        vals = [s[f"wer:{p}"] for s in usable if s[f"wer:{p}"] is not None]
        on = lambda lbl: [s[f"wer:{p}"] for s in usable if gold_ids.get(s["sample_id"]) == lbl and s[f"wer:{p}"] is not None]
        fmt = lambda v: f"{statistics.mean(v):.1%}" if v else "–"
        lines.append(f"| {p} | {len(vals)} | {statistics.median(vals):.1%} | {statistics.mean(vals):.1%} | {fmt(on('bad'))} | {fmt(on('good'))} |"
                     if vals else f"| {p} | 0 | – | – | – | – |")
    lines += ["", f"Gold set: {len(good)} good, {len(bad)} bad (gold.jsonl).",
              "References still unadjudicated: "
              f"{sum(s['ref_kind'] == 'sent' for s in scored)} of {len(scored)}. "
              "Until they are adjudicated, WER against sent text punishes any provider "
              "for errors the speaker didn't bother to fix."]
    (corpus / "report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
