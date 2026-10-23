#!/usr/bin/env python3
"""Development-only empirical policy translation; no audio or holdout results."""
import argparse
import hashlib
import importlib.util
import itertools
import json
import math
from pathlib import Path


def load_scorer(root):
    spec = importlib.util.spec_from_file_location("frozen_scorer", root / "scoring/scorer.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def development(rows, plan, scorer):
    scorer.validate_plan(rows, plan)
    selected = [r for r in rows
                if plan["group_roles"][r["session_group"]] == "dev"
                and plan["speaker_cohorts"][r["speaker_id"]] != "unknown_test"]
    if not selected:
        raise ValueError("No development support")
    return selected


def cache_vectors(root, rows, engine, run, scorer):
    """Derive exact cache addresses from metadata; never open other clips."""
    info = scorer.read_json(root / "engines" / run / "run.json")
    model = {k: v for k, v in info["models"][engine].items() if k != "load_ms"}
    vectors = {}
    for row in rows:
        metadata = dict(audio=row["content_sha256"], start=0, end=None,
                        worker=info["worker_sha256"], model=model,
                        ffmpeg=info["ffmpeg"], aggregation=info["aggregation"],
                        threads=info["threads"])
        key = hashlib.sha256(scorer.canonical(metadata).encode()).hexdigest()
        saved = scorer.read_json(root / "engines" / run / "cache" / (key + ".json"))
        if (saved["audio_sha256"] != row["content_sha256"]
                or saved["start_s"] != 0 or saved["end_s"] is not None
                or {k: v for k, v in saved["model"].items() if k != "load_ms"} != model
                or saved["result"]["status"] != "ok"):
            raise ValueError("Invalid development cache provenance")
        vectors[row["id"]] = scorer.normalize(saved["result"]["embedding"])
    return scorer.validate_embeddings(rows, vectors)


def cosine(a, b):
    return max(-1.0, min(1.0, math.fsum(x * y for x, y in zip(a, b))))


def observations(rows, vectors):
    """Unordered cross-session pairs and directed two-reference margin trials."""
    scores = {}
    positive, negative = [], []
    for a, b in itertools.combinations(rows, 2):
        if a["session_group"] == b["session_group"]:
            continue
        value = cosine(vectors[a["id"]], vectors[b["id"]])
        scores[a["id"], b["id"]] = scores[b["id"], a["id"]] = value
        (positive if a["speaker_id"] == b["speaker_id"] else negative).append(value)
    wrong, correct = [], []
    for anchor in rows:
        positives = [r for r in rows if r["speaker_id"] == anchor["speaker_id"]
                     and (anchor["id"], r["id"]) in scores]
        negatives = [r for r in rows if r["speaker_id"] != anchor["speaker_id"]
                     and (anchor["id"], r["id"]) in scores]
        for pos, neg in itertools.product(positives, negatives):
            genuine = scores[anchor["id"], pos["id"]]
            impostor = scores[anchor["id"], neg["id"]]
            wrong.append((impostor, impostor - genuine))
            correct.append((genuine, genuine - impostor))
    if not positive or not negative or not wrong:
        raise ValueError("Insufficient cross-session development pairs or margin trials")
    return dict(positive=positive, negative=negative, wrong=wrong, correct=correct)


def count(values, threshold):
    return sum(v >= threshold for v in values)


def choose(values, allowed, floor=0.0):
    """Lowest thousandth meeting an empirical count ceiling; equal blocks intact."""
    for step in range(math.ceil(floor * 1000), 2002):
        threshold = step / 1000
        if count(values, threshold) <= allowed:
            return threshold
    raise ValueError("No finite empirical threshold")


def rates(obs, threshold, margin, split):
    def metric(n, d):
        return {"accepted": n, "denominator": d, "rate": n / d if d else None}
    return {
        "impostor_pairs": metric(count(obs["negative"], threshold), len(obs["negative"])),
        "genuine_pairs": metric(count(obs["positive"], threshold), len(obs["positive"])),
        "genuine_split_pairs": metric(count(obs["positive"], split), len(obs["positive"])),
        "wrong_margin_only": metric(sum(m >= margin for _, m in obs["wrong"]), len(obs["wrong"])),
        "wrong_joint": metric(sum(s >= threshold and m >= margin for s, m in obs["wrong"]),
                              len(obs["wrong"])),
        "correct_joint": metric(sum(s >= threshold and m >= margin for s, m in obs["correct"]),
                                len(obs["correct"])),
    }


def calibrate(ecapa, wespeaker):
    for key in ecapa:
        if len(ecapa[key]) != len(wespeaker[key]):
            raise ValueError("Unpaired engines")
    # ADR 0006: do not lower naming thresholds on this evidence.
    # This floor is policy, not an assertion of cross-model scale equivalence.
    threshold = choose(wespeaker["negative"], count(ecapa["negative"], .55), floor=.55)
    margin = choose([m for _, m in wespeaker["wrong"]],
                    sum(m >= .15 for _, m in ecapa["wrong"]), floor=.15)
    # Also preserve the baseline joint wrong-claim count, not merely marginals.
    baseline_joint = sum(s >= .55 and m >= .15 for s, m in ecapa["wrong"])
    while sum(s >= threshold and m >= margin for s, m in wespeaker["wrong"]) > baseline_joint:
        margin = round(margin + .001, 3)
    split = choose(wespeaker["positive"], count(ecapa["positive"], .75), floor=threshold)
    def distribution(values):
        values = sorted(values)
        return {"minimum": values[0], "median": values[len(values) // 2],
                "maximum": values[-1]}
    return {
        "constants": {"match_threshold": threshold, "match_margin": margin, "split_threshold": split},
        "ecapa": rates(ecapa, .55, .15, .75),
        "wespeaker": rates(wespeaker, threshold, margin, split),
        "score_distributions": {
            engine: {
                "genuine_cosine": distribution(obs["positive"]),
                "impostor_cosine": distribution(obs["negative"]),
                "wrong_claim_margin": distribution([m for _, m in obs["wrong"]]),
                "correct_claim_margin": distribution([m for _, m in obs["correct"]]),
            } for engine, obs in (("ecapa", ecapa), ("wespeaker", wespeaker))
        },
    }


def run(root):
    scorer = load_scorer(root)
    rows = scorer.load_manifest(root / "manifest.json")
    plan = scorer.read_json(root / "scoring/frozen-splits-v2.json")
    selected = development(rows, plan, scorer)
    observed = {}
    for engine, run_name in (("ecapa", "production-ecapa"), ("wespeaker", "confirmed-whole")):
        vectors = cache_vectors(root, selected, engine, run_name, scorer)
        observed[engine] = observations(selected, vectors)
    report = calibrate(observed["ecapa"], observed["wespeaker"])
    report["support"] = {
        "development_clips": len(selected),
        "people": len({r["speaker_id"] for r in selected}),
        "sessions": len({r["session_group"] for r in selected}),
        "people_with_cross_session_positives": len({
            a["speaker_id"] for a, b in itertools.combinations(selected, 2)
            if a["speaker_id"] == b["speaker_id"] and a["session_group"] != b["session_group"]
        }),
    }
    private = root / "calibration"
    private.mkdir(mode=0o700, exist_ok=True)
    # Aggregate only, even in the private artifact. Exclusive creation.
    with (private / "policy-summary-v4.json").open("x") as stream:
        json.dump(report, stream, indent=2, allow_nan=False)
        stream.write("\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--benchmark", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(run(args.benchmark), indent=2, allow_nan=False))
    except Exception:
        # Upstream validation errors may contain private identifiers.
        parser.exit(2, "Calibration failed; private input validation or support error. No identifiers logged.\n")
