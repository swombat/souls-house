"""The store thread: the only caller of the store's connection in the running
connector, so the event loop never waits on the database (slice S2b-2; the
slice 1 baseline showed a restart freezing the loop for 4.9 s at 1,000
accounts, all of it synchronous store calls).

Every call is a job on one queue, run in the order submitted, one at a time,
on one thread: the same serial order the store had on the loop, so S2a's
ordering arguments (outbox before progress in one transaction, sequence
numbers without holes) hold unchanged. A region of store work that must not
interleave with other coroutines is submitted as one job (`run` / `unit`).

Cancellation: a job, once submitted, runs to its end and commits or rolls
back on its own terms. Cancelling the coroutine that awaits it only stops the
waiting; it never cancels, interrupts or rolls back the job. Shutdown runs
every job already queued, then closes the connection.

Fail-stop: the Postgres connection carries the process's advisory lock. If
it fails (an error the backend calls fatal) or goes silent (a job running
longer than `op_deadline`, or the idle heartbeat not answering), the process
exits at once and never reconnects in place: the container restarts and has
to take the volume lock and the advisory lock again before it opens any
client. Detection is bounded, not instant; see README "Store".
"""

import asyncio
import collections
import concurrent.futures
import logging
import os
import queue
import threading
import time

log = logging.getLogger("telegram.store")

EXIT_STORE_LOST = 75



def exit_now(reason):
    log.error("store lost; exiting: reason=%s", reason)
    logging.shutdown()
    os._exit(EXIT_STORE_LOST)


class Closed(Exception):
    pass


class Stats:
    """Queue wait (submitted to started) and execution (started to finished)
    per job, kept apart: moving a stall off the loop into the queue must stay
    visible."""

    def __init__(self, keep=20000):
        self.lock = threading.Lock()
        self.jobs = 0
        self.wait = collections.deque(maxlen=keep)
        self.run = collections.deque(maxlen=keep)
        self.wait_max = 0.0
        self.run_max = 0.0
        self.kinds = collections.Counter()
        self.kind_seconds = collections.Counter()
        self.wait_total = 0.0
        self.run_total = 0.0

    def record(self, wait, run, kind=None):
        with self.lock:
            self.jobs += 1
            self.wait_total += wait
            self.run_total += run
            if kind:
                self.kinds[kind] += 1
                self.kind_seconds[kind] += run
            self.wait.append(wait)
            self.run.append(run)
            self.wait_max = max(self.wait_max, wait)
            self.run_max = max(self.run_max, run)

    def snapshot(self, reset=False):
        with self.lock:
            data = {"jobs": self.jobs, "wait": list(self.wait), "run": list(self.run),
                    "wait_max": self.wait_max, "run_max": self.run_max, "kinds": dict(self.kinds),
                    "kind_seconds": dict(self.kind_seconds),
                    "wait_total": self.wait_total, "run_total": self.run_total}
            if reset:
                self.jobs, self.wait_max, self.run_max = 0, 0.0, 0.0
                self.wait_total = self.run_total = 0.0
                self.kinds.clear()
                self.kind_seconds.clear()
                self.wait.clear()
                self.run.clear()
            return data


class StoreThread:
    def __init__(self, store, on_fatal=exit_now, op_deadline=10.0, heartbeat=5.0, tick=1.0, stats_keep=20000):
        self.store = store
        self.on_fatal = on_fatal
        self.op_deadline = op_deadline
        self.heartbeat = heartbeat
        self.tick = tick
        # Per-job samples kept for percentiles (the maxima are exact); the
        # load harness keeps every job of a phase.
        self.stats = Stats(stats_keep)
        self._queue = queue.SimpleQueue()
        self._closed = False
        self._dead = None
        self._submit_lock = threading.Lock()
        self.busy_since = None
        self.last_finished = time.monotonic()
        self._thread = threading.Thread(target=self._work, name="store", daemon=True)
        self._thread.start()
        self._stop_watch = threading.Event()
        self._watch = None
        if heartbeat:
            self._watch = threading.Thread(target=self._watchdog, name="store-watchdog", daemon=True)
            self._watch.start()

    # -- submitting -------------------------------------------------------------

    def submit(self, fn, *args, job_kind=None, **kwargs):
        future = concurrent.futures.Future()
        with self._submit_lock:
            if self._closed:
                raise Closed()
            if self._dead:
                raise Closed(self._dead)
            self._queue.put((fn, args, kwargs, future, time.monotonic(), job_kind))
        return future

    async def call(self, fn, *args, job_kind=None, **kwargs):
        """Runs fn(*args) on the store thread and returns its result. The
        job is shielded: cancelling the caller does not cancel it. `job_kind`
        names the job in the statistics."""
        future = asyncio.wrap_future(self.submit(fn, *args, job_kind=job_kind, **kwargs))
        future.add_done_callback(_consume)
        return await asyncio.shield(future)

    # -- the thread -------------------------------------------------------------

    def _work(self):
        while True:
            item = self._queue.get()
            if item is None:
                break
            fn, args, kwargs, future, submitted, kind = item
            if not future.set_running_or_notify_cancel():
                continue
            started = time.monotonic()
            self.busy_since = started
            try:
                result = fn(*args, **kwargs)
            except BaseException as error:  # noqa: BLE001 (handed to the caller)
                self._finish(submitted, started, kind)
                if self.store.db.fatal and isinstance(error, self.store.db.fatal):
                    self._fail(f"store_error:{type(error).__name__}")
                future.set_exception(error)
            else:
                self._finish(submitted, started, kind)
                future.set_result(result)

    def _finish(self, submitted, started, kind=None):
        finished = time.monotonic()
        self.busy_since = None
        self.last_finished = finished
        self.stats.record(started - submitted, finished - started, kind)

    def _fail(self, reason):
        if self._dead:
            return
        self._dead = reason
        self.on_fatal(reason)

    def _watchdog(self):
        """Its own thread, so it fires even if the loop is stuck. A job that
        has been running longer than op_deadline is a stalled connection (a
        silent server, a black-holed route). When the store has been idle for
        `heartbeat`, a ping is queued, so an idle connection is checked too."""
        pinging = None
        while not self._stop_watch.wait(self.tick):
            now = time.monotonic()
            busy = self.busy_since
            if busy is not None and now - busy > self.op_deadline:
                self._fail("store_stalled")
                return
            if busy is None and now - self.last_finished >= self.heartbeat and (pinging is None or pinging.done()):
                try:
                    pinging = self.submit(self.store.ping, job_kind="heartbeat")
                except Closed:
                    return

    # -- shutdown ---------------------------------------------------------------

    def close(self, timeout=30):
        """Runs every job already queued, then closes the connection."""
        with self._submit_lock:
            if self._closed:
                return
            self._closed = True
            self._queue.put(None)
        self._stop_watch.set()
        self._thread.join(timeout)
        if not self._thread.is_alive():
            self.store.db.close()


def _kind(fn):
    # e.g. "Account.account_difference.apply": where the job came from.
    return getattr(fn, "__qualname__", "job").replace(".<locals>", "").replace("<lambda>", "λ")


def _consume(future):
    # The caller may have stopped waiting; retrieve the outcome so asyncio
    # does not report it as never retrieved.
    if not future.cancelled():
        future.exception()


class AsyncStore:
    """What the account, sync and delivery code holds: every Store method,
    awaited, run on the store thread. `run(fn)` runs fn(store) as one job;
    `unit(fn)` does the same inside one transaction."""

    def __init__(self, thread):
        self.thread = thread
        self.sync = thread.store

    def __getattr__(self, name):
        attribute = getattr(self.sync, name)
        if not callable(attribute):
            return attribute

        async def call(*args, **kwargs):
            return await self.thread.call(attribute, *args, job_kind=name, **kwargs)
        call.__name__ = name
        return call

    async def run(self, fn):
        return await self.thread.call(fn, self.sync, job_kind=_kind(fn))

    async def unit(self, fn):
        store = self.sync

        def job():
            with store.transaction():
                return fn(store)
        return await self.thread.call(job, job_kind=_kind(fn))

    def view(self):
        return BlockingView(self.thread)

    def close(self):
        self.thread.close()


def serve(store, **options):
    """The store behind its thread, as the running connector holds it."""
    return AsyncStore(StoreThread(store, **options))


class _Rows:
    def __init__(self, rows, rowcount):
        self._rows = rows
        self.rowcount = rowcount

    def fetchone(self):
        return self._rows[0] if self._rows else None

    def fetchall(self):
        return list(self._rows)

    def __iter__(self):
        return iter(self._rows)


class BlockingView:
    """For tests and tools outside the loop's flow: the store's methods,
    called synchronously but run on the store thread (never on the caller's
    thread, so the connection is only ever used by one thread). `db.execute`
    returns its rows already fetched."""

    def __init__(self, thread, target=None):
        object.__setattr__(self, "_thread", thread)
        object.__setattr__(self, "_target", target if target is not None else thread.store)

    def __setattr__(self, name, value):
        # Plain attributes (a test's fault hook) go to the store itself.
        setattr(self._target, name, value)

    def __getattr__(self, name):
        attribute = getattr(self._target, name)
        if name == "db":
            return BlockingView(self._thread, attribute)
        if not callable(attribute):
            return attribute
        if self._target is not self._thread.store and name == "execute":
            def execute(*args):
                def job():
                    cursor = attribute(*args)
                    rows = cursor.fetchall() if cursor.description else []
                    return _Rows(rows, cursor.rowcount)
                return self._thread.submit(job).result()
            return execute

        def call(*args, **kwargs):
            return self._thread.submit(attribute, *args, **kwargs).result()
        return call
