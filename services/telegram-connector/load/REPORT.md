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

# S2b slice 2: the store in Postgres, off the event loop

The same workload, seed and harness as slice 1. The connector's store is now
in Postgres, behind the store thread (`connector/storethread.py`;
`../README.md` "Store"), with Postgres 18.6 on the same host over a Unix
socket. Production reaches its database over Docker's network, so the round
trips here are the short ones. One run per size. The code that ships is
measured in `results/final2-{100,300,1000}.json`. The earlier passes the
readings go through are in `pg-*` (the first conversion), `pg3-*` (fewer jobs
and a 0.5 ms switch interval), `ab-300-si0005` (before the backfill fix) and
`ab2-300-si5`/`ab2-300-si05` (the switch-interval A/B).

## Table

| | baseline-100 | final2-100 | baseline-300 | final2-300 | baseline-1000 | final2-1000 |
|---|---|---|---|---|---|---|
| store | sqlite, on the loop thread (S2a) | postgres | sqlite, on the loop thread (S2a) | postgres | sqlite, on the loop thread (S2a) | postgres |
| accounts | 100 | 100 | 300 | 300 | 1000 | 1000 |
| connected / of | 100 / 100 | 100 / 100 | 300 / 300 | 300 / 300 | 1000 / 1000 | 1000 / 1000 |
| time to connected p50 / p95 / max (ms) | 64 / 92 / 116 | 138 / 374 / 443 | 65 / 114 / 146 | 242 / 481 / 542 | 66 / 104 / 144 | 161 / 246 / 288 |
| backfill: accounts done, wait (s) | 100, 3.0 | 100, 3.1 | 300, 3.0 | 300, 4.1 | 1000, 3.0 | 1000, 3.0 |
| steady duration (s), drain (s) | 300.0, 0.0 | 300.0, 0.0 | 300.0, 0.0 | 300.0, 0.0 | 300.0, 0.0 | 300.0, 0.0 |
| delivery idle: injected / undelivered | 129 / 0 | 129 / 0 | 404 / 0 | 404 / 0 | 1340 / 0 | 1340 / 0 |
| delivery idle p50 / p95 / p99 / max (ms) | 4 / 11 / 13 / 23 | 15 / 38 / 58 / 72 | 4 / 10 / 14 / 20 | 15 / 37 / 55 / 77 | 4 / 10 / 21 / 553 | 18 / 52 / 70 / 90 |
| delivery busy: injected / undelivered | 304 / 0 | 304 / 0 | 932 / 0 | 932 / 0 | 3066 / 0 | 3066 / 0 |
| delivery busy p50 / p95 / p99 / max (ms) | 4 / 11 / 14 / 16 | 15 / 29 / 58 / 64 | 4 / 11 / 13 / 20 | 15 / 36 / 57 / 77 | 4 / 9 / 20 / 74 | 19 / 53 / 71 / 618 |
| delivery abusive: injected / undelivered | 1458 / 0 | 1458 / 0 | 1458 / 0 | 1458 / 0 | 1458 / 0 | 1458 / 0 |
| delivery abusive p50 / p95 / p99 / max (ms) | 4 / 11 / 16 / 46 | 15 / 25 / 52 / 68 | 4 / 11 / 14 / 43 | 15 / 30 / 56 / 72 | 4 / 8 / 17 / 77 | 18 / 48 / 63 / 97 |
| search normal: n, errors/timeouts | 43, 0 | 43, 0 | 45, 0 | 45, 0 | 44, 0 | 44, 0 |
| search normal p50 / p95 / max (ms) | 4 / 5 / 7 | 7 / 11 / 15 | 3 / 5 / 8 | 7 / 11 / 15 | 5 / 6 / 8 | 8 / 15 / 19 |
| search abusive: n, errors/timeouts | 609, 0 | 609, 0 | 609, 0 | 609, 0 | 609, 0 | 609, 0 |
| search abusive p50 / p95 / max (ms) | 21 / 43 / 50 | 40 / 46 / 58 | 31 / 43 / 52 | 40 / 47 / 58 | 34 / 43 / 53 | 39 / 49 / 64 |
| loop lag onboard p50 / p99 / max (ms) | 5 / 37 / 39 | 0 / 2 / 2 | 8 / 53 / 67 | 0 / 2 / 3 | 10 / 51 / 69 | 0 / 1 / 3 |
| loop lag steady p50 / p99 / max (ms) | 1 / 26 / 42 | 1 / 32 / 44 | 1 / 29 / 49 | 1 / 31 / 43 | 1 / 31 / 543 | 1 / 32 / 461 |
| loop lag restart p50 / p99 / max (ms) | 1054 / 1054 / 1054 | 0 / 8 / 8 | 0 / 2864 / 2864 | 0 / 11 / 11 | 0 / 5488 / 5488 | 0 / 55 / 491 |
| restart: stop → booted (s) | 0.06 | 0.02 | 0.09 | 0.05 | 0.2 | 0.16 |
| restart: booted → every account's first message (s) | 1.36 | 1.5 | 2.92 | 3.0 | 9.02 | 11.19 |
| restart: stop → every account's first message (s) | 1.42 | 1.52 | 3.01 | 3.05 | 9.22 | 11.35 |
| restart: stop → idle account's first message, p50 / max (s) | 1.29 / 1.42 | 1.04 / 1.06 | 2.57 / 3.01 | 2.92 / 2.98 | 7.53 / 9.21 | 11.02 / 11.24 |
| store jobs onboard: n; queue wait p50 / p99 / max (ms) | not recorded (store on the loop) | 8449; 8 / 93 / 123 | not recorded (store on the loop) | 25167; 31 / 82 / 98 | not recorded (store on the loop) | 85024; 14 / 44 / 91 |
| store jobs onboard: execution p50 / p99 / max (ms) | not recorded | 0 / 9 / 66 | not recorded | 0 / 8 / 42 | not recorded | 0 / 7 / 67 |
| store jobs steady_and_drain: n; queue wait p50 / p99 / max (ms) | not recorded (store on the loop) | 21869; 0 / 3 / 41 | not recorded (store on the loop) | 37160; 0 / 5 / 43 | not recorded (store on the loop) | 92160; 0 / 9 / 556 |
| store jobs steady_and_drain: execution p50 / p99 / max (ms) | not recorded | 1 / 5 / 43 | not recorded | 1 / 5 / 43 | not recorded | 1 / 6 / 552 |
| store jobs restart: n; queue wait p50 / p99 / max (ms) | not recorded (store on the loop) | 2402; 93 / 272 / 284 | not recorded (store on the loop) | 6244; 279 / 764 / 787 | not recorded (store on the loop) | 20313; 1003 / 3336 / 3435 |
| store jobs restart: execution p50 / p99 / max (ms) | not recorded | 0 / 3 / 4 | not recorded | 0 / 3 / 11 | not recorded | 0 / 3 / 566 |
| harness RSS MB (fake + stub + driver + connector): worlds built → after onboard → after steady (peak) | 210.2 → 215.6 → 222.1 (222.3) | 219.2 → 224.4 → 232.0 (233.7) | 465.5 → 473.6 → 483.7 (484.9) | 474.5 → 484.6 → 496.3 (501.6) | 1359.6 → 1378.2 → 1400.5 (1403.9) | 1368.5 → 1394.4 → 1419.8 (1439.9) |
| FDs after onboard (no sockets: fake) | 10 | 8 | 10 | 8 | 10 | 8 |
| asyncio tasks, peak | 406 | 406 | 1206 | 1206 | 4006 | 4007 |
| outbox undelivered, max of 1 s samples (steady) | 1 | 1 | 1 | 2 | 1 | 2 |
| outbox count query, peak (ms) | 1.25 | 126.33 | 3.31 | 460.6 | 6.51 | 2837.86 |
| CPU s total / of which in the fake | 28.4 / 16.31 | 54.5 / 19.15 | 42.7 / 18.14 | 81.1 / 19.56 | 91.8 / 21.27 | 180.5 / 21.05 |
| Rails requests, cumulative from start through drain | 3417 | 3380 | 7391 | 7368 | 21440 | 21360 |
| Rails requests, steady + drain only | not recorded | 1871 | not recorded | 2859 | not recorded | 6351 |
| store size (MB) | 10.6 | 22.5 | 30.3 | 47.3 | 99.0 | 133.9 |
| GC gen2: count, max (ms); pauses >100 ms | not recorded | 0, –; 0 | not recorded | 0, –; 0 | 1, 546; 1 | 2, 561; 2 |
| warnings logged (WARNING and above) | unmeasured (logging was at ERROR) | none | unmeasured (logging was at ERROR) | none | unmeasured (logging was at ERROR) | none |

The restart rows now count from the stop. Slice 1's table counted "first
message" from the end of boot, which was instant on SQLite and wasn't on the
first Postgres passes. `baseline-*` keeps the slice-1 runs; the new rows are
computed from their recorded boot times.

## Readings

**The loop no longer freezes, but at 1,000 the restart takes longer.** The
store work moved from the loop to the store thread: the restart's loop lag
at 1,000 accounts is p99 55 ms (its 491 ms maximum is a full garbage
collection), where the baseline froze for 5,488 ms. The work itself did not
shrink. A restart still costs about 20 store jobs per account (resume, the
sequence check, the first sync pass, dialogs, the backfill check, the first
deliveries), and they run on one serial connection: 20,313 jobs and 10.5 s
of execution at 1,000 accounts, with queue wait p50 1.0 s and p99 3.3 s.
Counted from the stop, every account's first new message arrived 11.0–11.4 s
later (baseline 7.5–9.2 s). The spread is narrow, so the accounts don't come
up early one by one; they finish together, later. The loop stays responsive,
but anything that needs the store waits in the same queue. At 100 and 300
accounts the restart is about even with the baseline (median account from
the stop: 1.04 against 1.29 s, and 2.92 against 2.57 s). **So one store
connection is the restart's limit at 1,000, and slice 2 makes a 1,000-account
restart about 2–3.5 s slower in exchange for no frozen loop.** Raising that
limit means more connections (see "Not done here").

**Twice the first pass put the work in the wrong place, and the job
statistics found it.** On the first conversion (`pg-*`), 1,000 logins at
20/s took p50 6.9 s each to connect (it was 66 ms), and the backfill took 39.9 s
(it was 3.0). I had put each history page's whole construction on the
store thread: filtering and converting every message as well as the commit.
At 300 accounts, 18.8 s of the 25.9 s of onboarding execution was that one
kind of job. Building the page on the loop and committing it in a small job
that checks the cursor again brought onboarding to p50/p95
161/246 ms at 1,000 accounts (baseline 66/104), with backfill in 3.0 s. Separately,
`Manager.boot` did one store lookup per connection and awaited each resume:
at 1,000 accounts boot alone took 10.8 s. Boot now reads every connection
once. Job counts and execution seconds per kind are recorded in every result
now; without them, both of these would have looked like "Postgres is slow".

**Steady state costs latency, not throughput.** Delivery p50 rose from 4 ms
to 15–19 ms, and p99 from 13–21 ms to 52–71 ms; CPU roughly doubled. Every store call is now a hop to another thread and a round trip to
a server, where it used to be an in-process SQLite call. Steady queue wait
stays small (p99 3, 5 and 9 ms at 100, 300 and 1,000), so this is per-call cost, not contention. The
most frequent steady jobs are the saturation check before every fetch and
the delivery batch read. Reusing a saturation reading for 1 s failed two of
the saturation review tests, so every fetch still reads it fresh.

**The GIL convoy is real but didn't matter here.** In isolation, with the
loop kept 100% busy in pure Python, the store thread fell from about 8,000
trivial jobs/s to under 3. It releases the GIL on every socket wait and then
waits out CPython's 5 ms switch interval to get it back. At 0.5 ms it
managed about 150/s. On the real workload, once message work was off the
store thread, an A/B at 300 accounts showed no difference between 5 ms and
0.5 ms (time to connected p50 142 against 150 ms, delivery p99 55–62 against
55–59 ms, CPU 85.9 against 85.8 s), so the connector keeps CPython's default.
It is still a hazard: CPU-heavy work added to the loop slows the store thread
out of proportion. `--switch-interval` lets the harness measure it again.

**Full collections pause both threads.** At 1,000 accounts one generation-2
collection (up to 561 ms; two in the run) stalls the loop and, since it holds
the GIL, the store thread too: the steady phase's longest queue wait (556 ms)
and longest job (552 ms) are that pause. As in slice 1, the fake worlds make up most of the
heap.

**Run-to-run variance.** One run per size. The two 300-account runs on the
same onboarding code (`ab2-300-si5`, `final2-300`) differ by about 100 ms in
time to connected (p50 142 against 242 ms). Read differences smaller than that
as noise.

## Not established (in addition to slice 1's list)

- Postgres over Docker's network, as in production, instead of a local Unix
  socket. Every round trip is longer there, and so is the per-call cost
  above.
- Postgres shared with the house's own database under real load.

## Not done here

- **Restart pacing.** Slice 1 said the restart path needs pacing whatever
  the database. Off the loop, a restart freezes nothing. Pacing would spread
  the queue and push the last accounts' first message later, and the
  measured limit at 1,000 is the store's serial throughput. Pacing's real
  reason is Telegram's tolerance of many reconnects from one IP, which the
  fake can't show. Proposed: slice 3, with the supervisor (where a restart
  becomes per worker).
- **Parallel store connections**, sharded by connection so each keeps its
  order: the way to raise that throughput limit within one process. Not
  built; slice 3's workers each bring their own connection, and whether to
  shard before then is a call for review.
