# Load measurement (S2b slices 1–2)

`run.py` measures the connector *as it is* (S2a: one process, SQLite, every
connected account held live) under many accounts, so that later S2b slices
(Postgres store, leases and supervisor, scheduler, the pool) are compared
against the same seeded workload. Design: `docs/proposals/2026-10-11-telegram-personal-connections.md`
§12, plan agreed in souls.house YDbmqj (16 Nov).

```
cd services/telegram-connector
python -m load.run --label baseline-1000 --accounts 1000 --duration 300 --workdir /some/disk
```

Results go to `load/results/<label>.json` (summary plus one sample per
second); `REPORT.md` holds the readings.

Since slice 2 the store sits behind the store thread, as in the connector.
`--database-url postgresql://...` runs on Postgres instead of SQLite; the
connector's tables in that database are **dropped first**, so point it only
at a scratch database. Every result then also records, per phase (onboard,
steady + drain, restart), the store jobs: how many, queue wait and execution
time (percentiles and maxima), and the count and execution seconds of each
kind of job. `--switch-interval` overrides CPython's GIL switch interval for
an experiment; the connector keeps the default.

## What runs

The connector's own `Store`, `Manager`, `Account`, sync, backfill and delivery,
with production `Settings()` defaults, in one asyncio process, as the
accessory runs them. Nothing in `connector/` is patched. The only adaptation:
`RoutedManager` hands each connection the client factory of its own fake
`World`, because a `World` models one Telegram account.

Per run, in order:

1. **Onboarding.** `start_login` for every account at `--connect-rate` (20/s);
   the fake scans the QR after 50 ms; the account logs in, refreshes dialogs,
   syncs and backfills 30 days (history: 5 messages a day in each of three
   chats; the abusive tenant 50 a day, so its chats hit the 500 cap).
   Recorded: time to `connected` at Rails, time until every account's synced
   chats finish backfill.
2. **Steady state** (`--duration`, 300 s). Poisson message arrivals per
   account: idle accounts 0.2/min (≈290 a day, inside §1's 100–500), 10% busy
   accounts 6/min, one abusive tenant 300/min plus 120 searches/min; normal
   tenants share 10 searches/min. Each message body carries its injection
   time, and the stub Rails records when it arrives, so delivery latency is
   end to end (fake Telegram → sync → outbox → delivery → the stub Rails
   receiving the request; the clock stops there, before the ACK is returned).
3. **Drain**: until every injected message has reached Rails (or 300 s).
4. **Restart**: the process stops (manager closes, clients drop, store closes)
   and a new one boots on the same store, as a deploy does; one message per
   account is injected and timed to Rails.

Sampled throughout: event-loop lag (100 ms ticker), RSS, open FDs, asyncio
task count, undelivered outbox rows (and how long counting them takes), CPU,
Rails requests, all once a second (so a peak is the largest 1 s sample, not
a true maximum). Counted for the whole run: every log record at WARNING or
above (root logging is lowered to WARNING for the run and put back after;
`tests/test_load_harness.py` has the negative control). Rails requests are
recorded both cumulatively from process start through drain and as the
steady + drain delta. RSS is the whole harness process (fake worlds, stub
dictionaries, driver bookkeeping and the connector), not the connector alone.

## What it cannot establish

- **No sockets.** The fake opens no MTProto connections, so FDs and memory
  here exclude Telethon's network layer per session. The real per-session
  socket/FD/RSS cost needs real Telegram (test DCs) and is not extrapolated.
- **Shared process.** The fake, the stub Rails and the driver run in the
  connector's event loop. Time inside fake calls is measured (`fake_calls`)
  and reported beside CPU and lag; the fake's `messages()`/`search()` are
  linear scans, so its share grows with history size.
- **Stub Rails.** It checks sequence (consecutive, gap, duplicate) and
  acknowledges like `comms_events.rb`, but stores nothing, does not verify
  signatures (the connector still signs every request), and does not validate
  payloads or status values. Rails' own ingest cost is not measured.
- **Restart is drained.** The restart happens after the outbox has drained,
  and new messages are injected after boot, so it does not exercise replay of
  pending events or of an ambiguous ACK (sent by Rails, lost before the
  connector recorded it). It measures boot and the first new message only.
- **No Telegram limits.** FloodWait, rate limits and anti-abuse behaviour
  are not modelled; nothing here says what Telegram tolerates from one IP.
- **One host, one run each.** Numbers are from the machine named in each
  result's `host`, single runs, seeded (`--seed 1116`).
