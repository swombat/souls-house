"""S2b slice 1: measure the S2a connector under many accounts.

Runs the connector's own code (Store, Manager, Account, sync, delivery) in one
process, as production does, with production `Settings()` defaults, against
one fake Telegram World per connection and a lean stub Rails. Nothing in
`connector/` is changed or monkeypatched; the only adaptation is that the
client factory is chosen per connection (`RoutedManager`), because the fake
World models a single Telegram account.

What this can and cannot establish (see README.md in this directory):
- It measures the connector's event loop, SQLite store, outbox and delivery
  under a seeded workload, and how much work actually completes.
- The fake opens no sockets, so FD and memory per session exclude Telethon's
  MTProto connection; those need real Telegram (test DCs) and are not
  extrapolated here.
- The fake, the stub Rails and the driver share the process and its event
  loop. Time spent inside fake calls is measured and reported separately.
- Telegram's rate limits and anti-abuse behaviour are not modelled.

Usage (from services/telegram-connector, with requirements.txt installed):

    python -m load.run --accounts 100 --duration 300 --label a100

Writes load/results/<label>.json and prints a summary.
"""

import argparse
import asyncio
import datetime
import json
import logging
import os
import platform
import random
import resource
import shutil
import tempfile
import time

from connector.account import Settings
from connector.fake import ALICE, BOB, FAMILY, TEAM, World
from connector.manager import Manager
from connector.store import Crypto, Store

STORE_KEY = "k" * 40
MARK = "LOADT"          # message bodies: LOADT|<injected perf_counter>|<n>


# -- the fake's cost, measured --------------------------------------------------------

FAKE_SECONDS = {"total": 0.0, "calls": 0, "depth": 0}


def _timed(fn):
    """Times the outermost fake call only (search() calls messages())."""
    def wrapper(*args, **kwargs):
        if FAKE_SECONDS["depth"]:
            return fn(*args, **kwargs)
        FAKE_SECONDS["depth"] += 1
        started = time.perf_counter()
        try:
            return fn(*args, **kwargs)
        finally:
            FAKE_SECONDS["depth"] -= 1
            FAKE_SECONDS["total"] += time.perf_counter() - started
            FAKE_SECONDS["calls"] += 1
    return wrapper


for _name in ("difference", "channel_difference", "dialogs", "messages", "search", "add_message"):
    setattr(World, _name, _timed(getattr(World, _name)))


class RoutedManager(Manager):
    """The production Manager; each connection's client comes from its own World."""

    def __init__(self, worlds, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.worlds = worlds

    def account(self, ref, create=False):
        world = self.worlds.get(ref)
        if world is not None:
            self.factory = world.factory
        return super().account(ref, create)


# -- a lean Rails ---------------------------------------------------------------------

class StubRails:
    """Acks events in sequence like app/lib/comms_events.rb (committed_seq,
    409 on a gap, duplicates acknowledged), without storing bodies. Records
    when each injected message reaches it. Optional per-request latency and
    outage."""

    def __init__(self, latency=0.0):
        self.latency = latency
        self.down = False
        self.committed = {}
        self.connected_at = {}
        self.requests = 0
        self.by_type = {}
        self.delivered = {}           # (ref, n) -> latency seconds
        self.backfilled = 0
        self.history_from = {}

    async def post(self, path, body, headers):
        self.requests += 1
        if self.latency:
            await asyncio.sleep(self.latency)
        if self.down:
            raise ConnectionError("rails down")
        ref = path.split("/")[4]
        event = json.loads(body)
        kind = event.get("type")
        self.by_type[kind] = self.by_type.get(kind, 0) + 1
        seq = event.get("seq")
        committed = self.committed.get(ref, 0)
        if seq is not None:
            if seq <= committed:
                return 200, {"committed_seq": committed}
            if seq > committed + 1:
                return 409, {"error": "sequence_gap", "committed_seq": committed}
            self.committed[ref] = seq
        arrived = time.perf_counter()
        if kind == "status.changed" and event.get("status") == "connected":
            self.connected_at.setdefault(ref, arrived)
        elif kind == "message.upsert":
            for message in event.get("messages", []):
                text = message.get("body") or ""
                if text.startswith(MARK + "|"):
                    _, sent, n = text.split("|", 2)
                    self.delivered.setdefault((ref, n), arrived - float(sent))
                else:
                    self.backfilled += 1
        elif kind == "chat.upsert":
            for chat in event.get("chats", []):
                if (chat.get("sync_state") or {}).get("history_from"):
                    self.history_from[(ref, chat["provider_chat_id"])] = True
        return (200, {"committed_seq": seq}) if seq is not None else (204, {})


# -- observation ----------------------------------------------------------------------

class Problems(logging.Handler):
    def __init__(self):
        super().__init__(logging.WARNING)
        self.counts = {}

    def emit(self, record):
        key = record.getMessage().split(":")[0]
        self.counts[key] = self.counts.get(key, 0) + 1


def rss_mb():
    with open("/proc/self/status") as handle:
        for line in handle:
            if line.startswith("VmRSS:"):
                return int(line.split()[1]) / 1024
    return 0.0


def fds():
    return len(os.listdir("/proc/self/fd"))


def pct(values, q):
    if not values:
        return None
    values = sorted(values)
    index = min(len(values) - 1, max(0, int(round(q / 100 * (len(values) - 1)))))
    return round(values[index], 4)


def summary(values):
    return {"n": len(values), "p50": pct(values, 50), "p95": pct(values, 95), "p99": pct(values, 99),
            "max": round(max(values), 4) if values else None}


async def sleep_until(due, stop):
    """Sleeps until `due`; False (without sleeping past it) if `stop` comes first."""
    if due >= stop:
        await asyncio.sleep(max(0.0, stop - time.perf_counter()))
        return False
    await asyncio.sleep(max(0.0, due - time.perf_counter()))
    return True


class Sampler:
    """Loop lag from a 100 ms ticker; RSS, FDs and outbox depth every second."""

    def __init__(self, harness):
        self.harness = harness
        self.lags = []
        self.samples = []
        self.phase = "setup"

    async def ticker(self):
        loop = asyncio.get_running_loop()
        while True:
            expected = loop.time() + 0.1
            await asyncio.sleep(0.1)
            self.lags.append((self.phase, max(0.0, loop.time() - expected)))

    async def sampler(self):
        while True:
            await asyncio.sleep(1.0)
            store = self.harness.store
            started = time.perf_counter()
            pending = store.db.execute("SELECT COUNT(*) FROM outbox WHERE delivered = 0").fetchone()[0]
            query = time.perf_counter() - started
            usage = resource.getrusage(resource.RUSAGE_SELF)
            self.samples.append({
                "t": round(time.perf_counter() - self.harness.t0, 2), "phase": self.phase,
                "rss_mb": round(rss_mb(), 1), "fds": fds(), "outbox_pending": pending,
                "outbox_count_ms": round(query * 1000, 2), "cpu_s": round(usage.ru_utime + usage.ru_stime, 2),
                "rails_requests": self.harness.rails.requests, "fake_s": round(FAKE_SECONDS["total"], 2),
                "tasks": len(asyncio.all_tasks()),
            })

    def lag(self, phase):
        return summary([lag for p, lag in self.lags if p == phase])


# -- the harness ----------------------------------------------------------------------

class LoadHarness:
    def __init__(self, args):
        self.args = args
        self.rng = random.Random(args.seed)
        self.dir = tempfile.mkdtemp(prefix="tg-load-", dir=args.workdir)
        self.path = os.path.join(self.dir, "store.sqlite3")
        self.rails = StubRails(latency=args.rails_latency)
        self.refs = [f"svc_load_{i:05d}" for i in range(args.accounts)]
        n_busy = int(round(args.accounts * args.busy_fraction))
        self.abusive = self.refs[0] if args.abusive else None
        self.busy = set(self.refs[1:1 + n_busy]) if args.abusive else set(self.refs[:n_busy])
        self.worlds = {}
        for ref in self.refs:
            per_day = args.abusive_history_per_day if ref == self.abusive else args.history_per_day
            self.worlds[ref] = World(auto_scan=0.05, qr_ttl=30, history_days=40, history_per_day=per_day)
        self.settings = Settings()      # production defaults
        self.injected = {}               # (ref, n) -> perf_counter
        self.searches = {"normal": [], "abusive": []}
        self.search_errors = {"normal": 0, "abusive": 0}
        self.counter = 0
        self.t0 = time.perf_counter()
        self.open()

    def open(self):
        self.store = Store(self.path, Crypto(STORE_KEY))
        self.manager = RoutedManager(self.worlds, self.store, None, self.rails.post, self.settings, b"load")

    async def close_process(self):
        """What a container stop does: the manager closes, clients drop, the store closes."""
        await self.manager.close()
        self.store.db.close()
        for world in self.worlds.values():
            for client in list(world.clients):
                await client.disconnect()

    # onboarding
    async def connect_all(self):
        interval = 1.0 / self.args.connect_rate
        started = {}

        async def one(ref):
            started[ref] = time.perf_counter()
            status, reply = await self.manager.command(ref, "start_login", {
                "generation": 1, "callback_secret": "s" * 64, "callback_secret_version": 1})
            if status != 200:
                raise RuntimeError(f"start_login {status} {reply}")

        tasks = []
        for ref in self.refs:
            tasks.append(asyncio.ensure_future(one(ref)))
            await asyncio.sleep(interval)
        await asyncio.gather(*tasks)
        deadline = time.perf_counter() + self.args.onboard_timeout
        while len(self.rails.connected_at) < len(self.refs) and time.perf_counter() < deadline:
            await asyncio.sleep(0.5)
        return {ref: self.rails.connected_at[ref] - started[ref] for ref in self.rails.connected_at}

    def backfill_state(self):
        rows = self.store.db.execute(
            "SELECT ref, MIN(backfill_done) AS done FROM chats WHERE synced = 1 GROUP BY ref").fetchall()
        return sum(1 for row in rows if row[1]), len(rows)

    async def wait_backfill(self, timeout):
        started = time.perf_counter()
        while time.perf_counter() - started < timeout:
            done, total = self.backfill_state()
            if total and done == len(self.refs):
                break
            await asyncio.sleep(1.0)
        return time.perf_counter() - started, self.backfill_state()

    # steady traffic
    def inject(self, ref, chat=None):
        self.counter += 1
        n = str(self.counter)
        chat = chat or self.rng.choice((f"user:{ALICE}", f"chat:{FAMILY}", f"channel:{TEAM}"))
        sender = ALICE if chat.startswith("user:") else BOB
        sent = time.perf_counter()
        self.injected[(ref, n)] = sent
        self.worlds[ref].add_message(chat, f"{MARK}|{sent}|{n}", sender=sender)

    async def traffic(self, ref, per_minute, stop):
        rng = random.Random(f"{self.args.seed}:{ref}")
        rate = per_minute / 60.0
        due = time.perf_counter() + rng.uniform(0, 1.0 / rate)
        while True:
            if not await sleep_until(due, stop):
                return
            self.inject(ref)
            due += rng.expovariate(rate)

    async def search(self, ref, kind):
        started = time.perf_counter()
        try:
            status, reply = await asyncio.wait_for(
                self.manager.command(ref, "search", {"query": "old", "limit": 20, "scope": "synced"}),
                self.args.search_timeout)
            if status != 200:
                self.search_errors[kind] += 1
                return
            self.searches[kind].append(time.perf_counter() - started)
        except asyncio.TimeoutError:
            self.search_errors[kind] += 1

    async def searcher(self, refs, per_minute, kind, stop):
        rng = random.Random(f"{self.args.seed}:search:{kind}")
        rate = per_minute / 60.0
        due = time.perf_counter()
        while True:
            due += rng.expovariate(rate)
            if not await sleep_until(due, stop):
                return
            asyncio.ensure_future(self.search(rng.choice(refs), kind))

    async def steady(self, duration):
        stop = time.perf_counter() + duration
        jobs = []
        for ref in self.refs:
            if ref == self.abusive:
                rate = self.args.abusive_per_minute
            elif ref in self.busy:
                rate = self.args.busy_per_minute
            else:
                rate = self.args.idle_per_minute
            jobs.append(self.traffic(ref, rate, stop))
        normal = [ref for ref in self.refs if ref != self.abusive]
        jobs.append(self.searcher(normal, self.args.searches_per_minute, "normal", stop))
        if self.abusive:
            jobs.append(self.searcher([self.abusive], self.args.abusive_searches_per_minute, "abusive", stop))
        await asyncio.gather(*jobs)

    async def drain(self, timeout):
        started = time.perf_counter()
        while time.perf_counter() - started < timeout:
            if all(key in self.rails.delivered for key in self.injected):
                break
            await asyncio.sleep(0.5)
        return time.perf_counter() - started

    def delivery(self, keys=None):
        keys = list(self.injected) if keys is None else keys
        groups = {"idle": [], "busy": [], "abusive": []}
        missing = {"idle": 0, "busy": 0, "abusive": 0}
        for key in keys:
            ref = key[0]
            group = "abusive" if ref == self.abusive else "busy" if ref in self.busy else "idle"
            latency = self.rails.delivered.get(key)
            if latency is None:
                missing[group] += 1
            else:
                groups[group].append(latency)
        return {group: dict(summary(values), injected=len(values) + missing[group], undelivered=missing[group])
                for group, values in groups.items() if values or missing[group]}

    async def restart(self):
        """Stop the process and start a new one on the same store, like a deploy."""
        stopped = time.perf_counter()
        await self.close_process()
        self.open()
        await self.manager.boot()
        booted = time.perf_counter() - stopped
        keys = []
        for ref in self.refs:
            self.inject(ref, chat=f"user:{ALICE}")
            keys.append((ref, str(self.counter)))
        started = time.perf_counter()
        while time.perf_counter() - started < self.args.drain_timeout:
            if all(key in self.rails.delivered for key in keys):
                break
            await asyncio.sleep(0.5)
        return {"boot_s": round(booted, 2), "first_message_all_accounts_s": round(time.perf_counter() - started, 2),
                "delivery": self.delivery(keys)}


QUIET = []


def say(*parts):
    import sys
    if QUIET:
        return
    print(time.strftime("%H:%M:%S"), *parts, file=sys.stderr, flush=True)


async def main(args):
    if args.quiet:
        QUIET.append(True)
    problems = Problems()
    logging.basicConfig(level=logging.ERROR)
    logging.getLogger().addHandler(problems)
    rss_before_worlds = rss_mb()
    harness = LoadHarness(args)
    sampler = Sampler(harness)
    background = [asyncio.ensure_future(sampler.ticker()), asyncio.ensure_future(sampler.sampler())]
    result = {
        "label": args.label, "args": vars(args),
        "host": {"python": platform.python_version(), "cpus": os.cpu_count(), "platform": platform.platform(),
                 "store_dir": args.workdir or tempfile.gettempdir()},
        "settings": {name: getattr(harness.settings, name) for name in dir(Settings)
                     if not name.startswith("_") and not callable(getattr(Settings, name))},
        "rss_mb": {"before_worlds": round(rss_before_worlds, 1), "after_worlds": round(rss_mb(), 1)},
    }
    try:
        sampler.phase = "onboard"
        say("onboard", len(harness.refs))
        connected = await harness.connect_all()
        say("connected", len(connected))
        result["onboard"] = {"connected": len(connected), "of": len(harness.refs),
                             "time_to_connected_s": summary(list(connected.values()))}
        backfill_s, (done, total) = await harness.wait_backfill(args.backfill_timeout)
        result["onboard"].update({"backfill_wait_s": round(backfill_s, 1), "accounts_backfilled": done,
                                  "accounts_with_synced_chats": total, "backfilled_messages": harness.rails.backfilled})
        say("backfilled", done, "of", total, "in", round(backfill_s, 1))
        result["rss_mb"]["after_onboard"] = round(rss_mb(), 1)
        result["fds_after_onboard"] = fds()

        sampler.phase = "steady"
        steady_started = time.perf_counter()
        await harness.steady(args.duration)
        sampler.phase = "drain"
        say("steady done; injected", len(harness.injected), "delivered", len(harness.rails.delivered))
        drain_s = await harness.drain(args.drain_timeout)
        say("drained in", round(drain_s, 1), "delivered", len(harness.rails.delivered))
        result["steady"] = {
            "duration_s": round(time.perf_counter() - steady_started - drain_s, 1), "drain_s": round(drain_s, 1),
            "delivery_latency_s": harness.delivery(),
            "search_latency_s": {kind: dict(summary(values), errors_or_timeouts=harness.search_errors[kind])
                                 for kind, values in harness.searches.items()},
            "rails_requests": harness.rails.requests, "rails_by_type": harness.rails.by_type,
        }
        result["rss_mb"]["after_steady"] = round(rss_mb(), 1)

        if args.restart:
            sampler.phase = "restart"
            say("restart")
            profiler = None
            if args.profile_restart:
                import cProfile
                profiler = cProfile.Profile()
                profiler.enable()
            result["restart"] = await harness.restart()
            if profiler:
                import io
                import pstats
                profiler.disable()
                text = io.StringIO()
                pstats.Stats(profiler, stream=text).sort_stats("tottime").print_stats(25)
                result["restart"]["profile_tottime_top25"] = text.getvalue()
            say("restart done", result["restart"]["boot_s"], result["restart"]["first_message_all_accounts_s"])

        result["loop_lag_s"] = {phase: sampler.lag(phase) for phase in ("onboard", "steady", "drain", "restart")}
        result["fake_calls"] = {"seconds": round(FAKE_SECONDS["total"], 2), "calls": FAKE_SECONDS["calls"]}
        usage = resource.getrusage(resource.RUSAGE_SELF)
        result["cpu_s"] = round(usage.ru_utime + usage.ru_stime, 1)
        result["max_rss_mb"] = round(usage.ru_maxrss / 1024, 1)
        result["store_bytes"] = os.path.getsize(harness.path)
        result["warnings"] = problems.counts
        result["samples"] = sampler.samples
    finally:
        for task in background:
            task.cancel()
        try:
            await harness.close_process()
        except Exception:
            pass
        if not args.keep:
            shutil.rmtree(harness.dir, ignore_errors=True)
    out_dir = args.out or os.path.join(os.path.dirname(__file__), "results")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f"{args.label}.json")
    with open(out, "w") as handle:
        json.dump(result, handle, indent=1, default=str)
    printable = {k: v for k, v in result.items() if k not in ("samples", "args", "settings")}
    if not args.quiet:
        print(json.dumps(printable, indent=1, default=str))
        print("written:", out)
    return result


def parse(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--label", required=True)
    p.add_argument("--accounts", type=int, default=100)
    p.add_argument("--seed", type=int, default=1116)
    p.add_argument("--duration", type=float, default=300.0, help="steady-state seconds")
    p.add_argument("--busy-fraction", type=float, default=0.10)
    p.add_argument("--idle-per-minute", type=float, default=0.2, help="≈ 290 messages/day/account")
    p.add_argument("--busy-per-minute", type=float, default=6.0)
    p.add_argument("--abusive", type=int, default=1, help="1: account 0 is the abusive tenant")
    p.add_argument("--abusive-per-minute", type=float, default=300.0)
    p.add_argument("--abusive-searches-per-minute", type=float, default=120.0)
    p.add_argument("--abusive-history-per-day", type=int, default=50)
    p.add_argument("--history-per-day", type=int, default=5)
    p.add_argument("--searches-per-minute", type=float, default=10.0, help="pool-wide, normal tenants")
    p.add_argument("--search-timeout", type=float, default=30.0)
    p.add_argument("--connect-rate", type=float, default=20.0, help="start_login commands per second")
    p.add_argument("--rails-latency", type=float, default=0.0)
    p.add_argument("--onboard-timeout", type=float, default=600.0)
    p.add_argument("--backfill-timeout", type=float, default=900.0)
    p.add_argument("--drain-timeout", type=float, default=300.0)
    p.add_argument("--restart", type=int, default=1)
    p.add_argument("--workdir", default=None, help="where the SQLite store lives (default: system temp)")
    p.add_argument("--keep", action="store_true")
    p.add_argument("--quiet", action="store_true")
    p.add_argument("--out", default=None, help="results directory (default: load/results)")
    p.add_argument("--profile-restart", type=int, default=1, help="cProfile the restart phase")
    return p.parse_args(argv)


if __name__ == "__main__":
    asyncio.run(main(parse()))
