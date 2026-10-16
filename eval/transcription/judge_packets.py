"""Write one adjudication packet per sample where the transcripts disagree.

    python3 judge_packets.py CORPUS_DIR [--threshold 0.03]

A judge model can't hear the audio. What it can do is read the conversation
context, the sent text and every provider's transcript, and decide word by
word which reading is the speaker's. Its output goes to
references/<sample_id>.txt, with a one-line confidence note in
references/<sample_id>.note. Low-confidence samples are for a human ear.
"""
import argparse
import json
import pathlib

from report import load_run
from textnorm import wer
from transcribe import load_manifest

INSTRUCTIONS = """You are adjudicating what a speaker actually said in a dictated chat message.
You cannot hear the audio. You have: the conversation just before it, the text the
speaker finally sent (they may have corrected the machine transcript, left errors
in, or rewritten parts), and independent machine transcripts of the same audio.

Write the most likely verbatim transcript (fillers may be dropped). Where the
transcripts agree, keep them. Where they disagree, prefer the reading that fits the
context and is acoustically plausible given the others. If the sent text adds
content no transcript has, the speaker rewrote it: do not include the addition.

Answer with exactly two parts:
TRANSCRIPT:
<text>
CONFIDENCE: high | medium | low — <one line on what was hard>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus", type=pathlib.Path)
    ap.add_argument("--threshold", type=float, default=0.03)
    args = ap.parse_args()
    corpus = args.corpus
    providers = sorted(p.name for p in (corpus / "runs").iterdir() if p.is_dir())
    out_dir = corpus / "packets"
    out_dir.mkdir(exist_ok=True)
    written = 0
    for row in load_manifest(corpus):
        if (corpus / "references" / f"{row['sample_id']}.txt").exists():
            continue
        hyps = {p: r["text"] for p in providers if (r := load_run(corpus, p, row["sample_id"]))}
        texts = [row["sent_text"], *hyps.values()]
        worst = max((wer(a, b)["wer"] for i, a in enumerate(texts) for b in texts[i + 1:]), default=0)
        if worst < args.threshold:
            continue
        ctx = "\n".join(f"[{c['role']}] {c['content']}" for c in row.get("context", []))
        body = [INSTRUCTIONS, "## Conversation before the message", ctx or "(none)",
                "## Text the speaker sent" + (" (then deleted the message)" if row["discarded"] else ""),
                row["sent_text"], "## Machine transcripts"]
        body += [f"### {p}\n{t}" for p, t in hyps.items()]
        (out_dir / f"{row['sample_id']}.md").write_text("\n\n".join(body) + "\n")
        written += 1
    print(f"{written} packets in {out_dir}")


if __name__ == "__main__":
    main()
