"""Render load/results/*.json as one markdown table (for REPORT.md).

    python -m load.report baseline-100 baseline-300 baseline-1000
"""

import json
import os
import sys

HERE = os.path.dirname(__file__)


def load(label):
    with open(os.path.join(HERE, "results", f"{label}.json")) as handle:
        return json.load(handle)


def g(data, *path):
    for key in path:
        if not isinstance(data, dict) or key not in data:
            return None
        data = data[key]
    return data


def ms(value):
    return "–" if value is None else f"{value * 1000:.0f}"


def peak(samples, key, phase=None):
    values = [s[key] for s in samples if phase is None or s["phase"] == phase]
    return max(values) if values else None


ROWS = [
    ("accounts", lambda r: r["args"]["accounts"]),
    ("connected / of", lambda r: f'{g(r, "onboard", "connected")} / {g(r, "onboard", "of")}'),
    ("time to connected p50 / p95 / max (ms)", lambda r: " / ".join(
        ms(g(r, "onboard", "time_to_connected_s", q)) for q in ("p50", "p95", "max"))),
    ("backfill: accounts done, wait (s)", lambda r: f'{g(r, "onboard", "accounts_backfilled")}, '
                                                    f'{g(r, "onboard", "backfill_wait_s")}'),
    ("steady duration (s), drain (s)", lambda r: f'{g(r, "steady", "duration_s")}, {g(r, "steady", "drain_s")}'),
]
for group in ("idle", "busy", "abusive"):
    ROWS.append((f"delivery {group}: injected / undelivered", lambda r, g_=group: (
        f'{g(r, "steady", "delivery_latency_s", g_, "injected")} / '
        f'{g(r, "steady", "delivery_latency_s", g_, "undelivered")}')))
    ROWS.append((f"delivery {group} p50 / p95 / p99 / max (ms)", lambda r, g_=group: " / ".join(
        ms(g(r, "steady", "delivery_latency_s", g_, q)) for q in ("p50", "p95", "p99", "max"))))
for kind in ("normal", "abusive"):
    ROWS.append((f"search {kind}: n, errors/timeouts", lambda r, k=kind: (
        f'{g(r, "steady", "search_latency_s", k, "n")}, {g(r, "steady", "search_latency_s", k, "errors_or_timeouts")}')))
    ROWS.append((f"search {kind} p50 / p95 / max (ms)", lambda r, k=kind: " / ".join(
        ms(g(r, "steady", "search_latency_s", k, q)) for q in ("p50", "p95", "max"))))
for phase in ("onboard", "steady", "restart"):
    ROWS.append((f"loop lag {phase} p50 / p99 / max (ms)", lambda r, p=phase: " / ".join(
        ms(g(r, "loop_lag_s", p, q)) for q in ("p50", "p99", "max"))))
ROWS += [
    ("restart: all accounts' first message (s)", lambda r: g(r, "restart", "first_message_all_accounts_s")),
    ("harness RSS MB (fake + stub + driver + connector): worlds built → after onboard → after steady (peak)", lambda r: (
        f'{g(r, "rss_mb", "after_worlds")} → {g(r, "rss_mb", "after_onboard")} → '
        f'{g(r, "rss_mb", "after_steady")} ({r.get("max_rss_mb")})')),
    ("FDs after onboard (no sockets: fake)", lambda r: r.get("fds_after_onboard")),
    ("asyncio tasks, peak", lambda r: peak(r["samples"], "tasks")),
    ("outbox undelivered, max of 1 s samples (steady)", lambda r: peak(r["samples"], "outbox_pending", "steady")),
    ("outbox count query, peak (ms)", lambda r: peak(r["samples"], "outbox_count_ms")),
    ("CPU s total / of which in the fake", lambda r: f'{r.get("cpu_s")} / {g(r, "fake_calls", "seconds")}'),
    ("Rails requests, cumulative from start through drain", lambda r: next(
        (v for v in (g(r, "steady", "rails_requests_cumulative_through_drain"), g(r, "steady", "rails_requests"))
         if v is not None), None)),
    ("Rails requests, steady + drain only", lambda r: (
        "not recorded" if g(r, "steady", "rails_requests_steady_and_drain") is None
        else g(r, "steady", "rails_requests_steady_and_drain"))),
    ("store size (MB)", lambda r: round(r.get("store_bytes", 0) / 1e6, 1)),
    ("GC gen2: count, max (ms); pauses >100 ms", lambda r: (
        "not recorded" if "gc" not in r else
        f'{g(r, "gc", "gen2", "n")}, {ms(g(r, "gc", "gen2", "max"))}; {len(g(r, "gc", "over_100ms") or [])}')),
    ("warnings logged (WARNING and above)", lambda r: (
        "unmeasured (logging was at ERROR)" if not r.get("warnings_measured") else
        ", ".join(f"{k}: {v}" for k, v in (r.get("warnings") or {}).items()) or "none")),
]


def main(labels):
    results = [load(label) for label in labels]
    print("| | " + " | ".join(labels) + " |")
    print("|---" * (len(labels) + 1) + "|")
    for name, fn in ROWS:
        cells = []
        for result in results:
            try:
                cells.append(str(fn(result)))
            except Exception:
                cells.append("–")
        print(f"| {name} | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main(sys.argv[1:])
