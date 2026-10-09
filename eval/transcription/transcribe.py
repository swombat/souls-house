"""Run providers over an exported corpus, caching every result.

    python3 transcribe.py CORPUS_DIR --providers scribe_v2,gemini-2.5-flash [--limit 20]

Results go to CORPUS_DIR/runs/<provider>/<sample_id>.json. A cached result is
never re-requested, so a run can be stopped and resumed without paying twice.
"""
import argparse
import json
import pathlib
import sys
import time
from concurrent.futures import ThreadPoolExecutor

from providers import PROVIDERS, ProviderUnavailable, guess_type


def load_manifest(corpus):
    return [json.loads(line) for line in (corpus / "manifest.jsonl").read_text().splitlines() if line.strip()]


def run_one(corpus, name, row):
    out = corpus / "runs" / name / f"{row['sample_id']}.json"
    if out.exists():
        return "cached"
    audio = corpus / row["audio_path"]
    started = time.time()
    try:
        result = PROVIDERS[name](str(audio), row.get("content_type") or guess_type(str(audio)))
    except ProviderUnavailable:
        raise
    except Exception as e:  # recorded, not retried silently
        result = {"error": f"{type(e).__name__}: {e}"}
    result["seconds"] = round(time.time() - started, 2)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, ensure_ascii=False, indent=1))
    return "error" if "error" in result else "ok"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus", type=pathlib.Path)
    ap.add_argument("--providers", default="scribe_v2")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--workers", type=int, default=4)
    args = ap.parse_args()

    rows = load_manifest(args.corpus)[: args.limit]
    for name in args.providers.split(","):
        if name not in PROVIDERS:
            sys.exit(f"unknown provider {name}; known: {', '.join(PROVIDERS)}")
        counts = {}
        with ThreadPoolExecutor(args.workers) as pool:
            for status in pool.map(lambda r: run_one(args.corpus, name, r), rows):
                counts[status] = counts.get(status, 0) + 1
        print(name, counts)


if __name__ == "__main__":
    try:
        main()
    except ProviderUnavailable as e:
        sys.exit(f"provider unavailable: {e}")
