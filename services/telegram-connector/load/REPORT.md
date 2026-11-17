# S2b slice 1: the S2a connector under 100, 300 and 1,000 accounts

Baseline for the S2b slices (souls.house YDbmqj, 16 Nov 2026). Workload,
method and limits: `README.md` in this directory. Raw results:
`results/baseline-{100,300,1000}.json`. Connector code: master at 5d9966d3,
unchanged.

Host: the souls.house Hetzner box, inside a resident container (12 CPUs,
125 GB RAM, ext4 on md RAID); Python 3.13.5; Telethon 1.41.2. One run per
size, seed 1116. Every run: production `Settings()`, start_login at 20/s,
300 s of steady traffic, drain, then a restart on the same store.

## Table

| | baseline-100 | baseline-300 | baseline-1000 |
|---|---|---|---|
| accounts | 100 | 300 | 1000 |
| connected / of | 100 / 100 | 300 / 300 | 1000 / 1000 |
| time to connected p50 / p95 / max (ms) | 64 / 92 / 116 | 65 / 114 / 146 | 66 / 104 / 144 |
| backfill: accounts done, wait (s) | 100, 3.0 | 300, 3.0 | 1000, 3.0 |
| steady duration (s), drain (s) | 300.0, 0.0 | 300.0, 0.0 | 300.0, 0.0 |
| delivery idle: injected / undelivered | 129 / 0 | 404 / 0 | 1340 / 0 |
| delivery idle p50 / p95 / p99 / max (ms) | 4 / 11 / 13 / 23 | 4 / 10 / 14 / 20 | 4 / 10 / 21 / 553 |
| delivery busy: injected / undelivered | 304 / 0 | 932 / 0 | 3066 / 0 |
| delivery busy p50 / p95 / p99 / max (ms) | 4 / 11 / 14 / 16 | 4 / 11 / 13 / 20 | 4 / 9 / 20 / 74 |
| delivery abusive: injected / undelivered | 1458 / 0 | 1458 / 0 | 1458 / 0 |
| delivery abusive p50 / p95 / p99 / max (ms) | 4 / 11 / 16 / 46 | 4 / 11 / 14 / 43 | 4 / 8 / 17 / 77 |
| search normal: n, errors/timeouts | 43, 0 | 45, 0 | 44, 0 |
| search normal p50 / p95 / max (ms) | 4 / 5 / 7 | 3 / 5 / 8 | 5 / 6 / 8 |
| search abusive: n, errors/timeouts | 609, 0 | 609, 0 | 609, 0 |
| search abusive p50 / p95 / max (ms) | 21 / 43 / 50 | 31 / 43 / 52 | 34 / 43 / 53 |
| loop lag onboard p50 / p99 / max (ms) | 5 / 37 / 39 | 8 / 53 / 67 | 10 / 51 / 69 |
| loop lag steady p50 / p99 / max (ms) | 1 / 26 / 42 | 1 / 29 / 49 | 1 / 31 / 543 |
| loop lag restart p50 / p99 / max (ms) | 1054 / 1054 / 1054 | 0 / 2864 / 2864 | 0 / 5488 / 5488 |
| restart: all accounts' first message (s) | 1.36 | 2.92 | 9.02 |
| harness RSS MB (fake + stub + driver + connector): worlds built → after onboard → after steady (peak) | 210.2 → 215.6 → 222.1 (222.3) | 465.5 → 473.6 → 483.7 (484.9) | 1359.6 → 1378.2 → 1400.5 (1403.9) |
| FDs after onboard (no sockets: fake) | 10 | 10 | 10 |
| asyncio tasks, peak | 406 | 1206 | 4006 |
| outbox undelivered, max of 1 s samples (steady) | 1 | 1 | 1 |
| outbox count query, peak (ms) | 1.25 | 3.31 | 6.51 |
| CPU s total / of which in the fake | 28.4 / 16.31 | 42.7 / 18.14 | 91.8 / 21.27 |
| Rails requests, cumulative from start through drain | 3417 | 7391 | 21440 |
| Rails requests, steady + drain only | not recorded | not recorded | not recorded |
| store size (MB) | 10.6 | 30.3 | 99.0 |
| GC gen2: count, max (ms); pauses >100 ms | not recorded | not recorded | 1, 546; 1 |
| warnings logged (WARNING and above) | unmeasured (logging was at ERROR) | unmeasured (logging was at ERROR) | unmeasured (logging was at ERROR) |

GC was not recorded for 100 and 300: GC recording was added for the 1,000
rerun (below), after those two had run. The 1,000 column is the rerun.

Three labels were corrected after review (17 Nov); the raw results are
unchanged. These runs set root logging to ERROR, so warnings were never
admitted and that row is unmeasured, not "none" (fixed in the driver since,
with a negative-control test; not rerun for this field alone). The Rails
request count is cumulative from process start through drain, onboarding
included; the 1,000-account run had already sent 15,029 by its first steady
sample. New runs record the steady + drain delta as well.

## Readings

**Steady state is not the problem at 1,000.** Every injected message reached
the stub Rails at every size, and delivery p99 stayed at 21 ms or under for
idle, busy and the abusive tenant alike, so the abusive tenant (300 messages and
120 searches a minute, chats at the 500-message backfill cap) did not move
the normal tenants' latency at this offered load. Loop-lag p99 was 26–31 ms.
Sampled once a second, the outbox never showed more than one undelivered
row (a sampled maximum, not a true one). The steady phase's
offered load is light by design, though (≈3.3 idle + 10 busy + 5 abusive
messages a second at 1,000), and it does not test saturation; slice 5's
scenarios (Rails at 2 s, Rails down an hour, all live with heavy traffic)
are where saturation gets tested.

**Restart is the problem, and it is the store, on the loop thread.** A restart
freezes the event loop for one long stretch: 1.05 s at 100 accounts, 2.86 s
at 300, 5.5 s at 1,000, and every account's first new message reached Rails
1.4 s, 2.9 s and 9.0 s after the restart. Profiled at 1,000: 6.7 s of the
9.2 s is inside `sqlite3.Connection.execute`, 63,095 statements. The store
runs WAL with `synchronous=FULL`, so each commit fsyncs, and every store call
is synchronous on the asyncio thread. Measured on the same disk: a WAL commit
at `synchronous=FULL` takes p50 3.8 ms / p95 6.1 ms (~250 commits/s for the
whole process); at `NORMAL`, 0.01 ms. During that stretch no account
receives, delivers or answers a search. It grows linearly with accounts.
Onboarding shows a milder version of the same thing (loop-lag p99 51 ms at
1,000, because the 20/s connect rate spreads it out).

For slice 2: moving the store to Postgres changes the commit cost, but the
same shape returns if store calls stay synchronous on the loop. The store
needs to be off the event-loop thread (async driver or a bounded executor),
and the restart path needs pacing (§4.1's reconnect token bucket), whichever
database it is. `synchronous=NORMAL` is not proposed as a fix here: it
changes what survives a power loss, and the outbox/progress argument would
have to be re-made for it.

**One stall in steady state, and it is garbage collection.** At 1,000 the
steady phase had a single 543 ms loop stall (one idle message took 553 ms).
GC recording attributed it: one generation-2 (full) collection, 546 ms, at the
same moment; every other collection stayed under 27 ms (136 gen-0, 13 gen-1).
Most of the heap here is the fake worlds (~1.36 GB), so this run overstates the
pause the connector would cause alone. The connector's heap with 1,000 real
Telethon clients is not measured. Python's full collection scales with live
objects, and any per-session object count that multiplies by a few hundred
sessions per worker is a pause the pool will have; slice 5 should record GC
on the pool the same way.

**Memory and tasks, without sockets.** The harness process's RSS grew ~12 MB,
~18 MB and ~41 MB from the worlds being built to the end of the steady phase,
for 100, 300 and 1,000 accounts (≈30–35 KB per account). That is incremental
harness RSS, not isolated connector memory: fake history, stub dictionaries
and driver bookkeeping grow in the same process, so it bounds the
connector's growth from above. The connector runs four asyncio tasks per account (sync,
backfill, delivery, plus resume or login). This excludes Telethon's MTProto
connection, sender and receive loops per client, which the fake does not
create: the real per-session socket, FD and memory cost is still unmeasured
and needs Telegram's test DCs. FDs here stayed at 10.

**What the fake costs.** CPU inside fake calls was 16, 18 and 21 s of 28, 43
and 92 s total. The figures above include it, so the connector's own CPU is
lower than they show. The fake's search and history are linear scans.

## Not established

- Real Telethon per-session cost (sockets, FDs, memory, its own tasks).
- Telegram's rate limits, FloodWait behaviour at volume, anti-abuse from one IP.
- Rails' ingest cost (the stub stores nothing).
- Saturation and recovery: Rails slow or down, all accounts live with heavy
  traffic, concurrent onboarding backfills of large histories. Slice 5.
- Anything about 10,000.
