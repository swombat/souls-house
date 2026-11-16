# Load measurement (S2b slice 1)

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
   end to end (fake Telegram → sync → outbox → delivery → Rails ack).
3. **Drain**: until every injected message has reached Rails (or 300 s).
4. **Restart**: the process stops (manager closes, clients drop, store closes)
   and a new one boots on the same store, as a deploy does; one message per
   account is injected and timed to Rails.

Sampled throughout: event-loop lag (100 ms ticker), RSS, open FDs, asyncio
task count, undelivered outbox rows (and how long counting them takes), CPU,
Rails requests, warnings logged by the connector.

## What it cannot establish

- **No sockets.** The fake opens no MTProto connections, so FDs and memory
  here exclude Telethon's network layer per session. The real per-session
  socket/FD/RSS cost needs real Telegram (test DCs) and is not extrapolated.
- **Shared process.** The fake, the stub Rails and the driver run in the
  connector's event loop. Time inside fake calls is measured (`fake_calls`)
  and reported beside CPU and lag; the fake's `messages()`/`search()` are
  linear scans, so its share grows with history size.
- **Stub Rails.** It checks sequence and acknowledges like `comms_events.rb`
  but stores nothing and does not verify signatures (the connector still
  signs every request). Rails' own ingest cost is not measured.
- **No Telegram limits.** FloodWait, rate limits and anti-abuse behaviour
  are not modelled; nothing here says what Telegram tolerates from one IP.
- **One host, one run each.** Numbers are from the machine named in each
  result's `host`, single runs, seeded (`--seed 1116`).
