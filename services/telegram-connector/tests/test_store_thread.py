"""The store thread (connector/storethread.py): order, cancellation,
shutdown, the queue-wait/execution split, and fail-stop."""

import asyncio
import os
import socket
import tempfile
import threading
import time
import unittest

from connector.store import Crypto, PostgresBackend, Store, connect_postgres
from connector.storethread import Closed, StoreThread, serve
from tests import pg


def sqlite_store():
    return Store(os.path.join(tempfile.mkdtemp(), "s.sqlite3"), Crypto("k" * 40))


class Recorder:
    def __init__(self):
        self.reasons = []
        self.event = threading.Event()

    def __call__(self, reason):
        self.reasons.append(reason)
        self.event.set()


class StoreThreadTest(unittest.IsolatedAsyncioTestCase):
    async def test_jobs_run_in_submission_order_one_at_a_time(self):
        astore = serve(sqlite_store(), heartbeat=0)
        seen, running = [], []

        def job(n):
            running.append(n)
            assert len(running) == 1, "two jobs at once"
            time.sleep(0.005)
            seen.append(n)
            running.pop()
        await asyncio.gather(*(astore.thread.call(job, n) for n in range(20)))
        self.assertEqual(list(range(20)), seen)
        astore.close()

    async def test_a_cancelled_caller_does_not_cancel_or_roll_back_its_job(self):
        astore = serve(sqlite_store(), heartbeat=0)
        await astore.ensure_connection("svc_1")
        started = threading.Event()

        def slow(store):
            store.update_connection("svc_1", status="written")
            started.set()
            time.sleep(0.3)
            store.enqueue("svc_1", {"type": "connector.availability", "state": "ok"})
        task = asyncio.create_task(astore.unit(slow))
        await asyncio.to_thread(started.wait, 5)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        # The job is still running; once it ends, its transaction committed.
        view = astore.view()
        self.assertEqual("written", view.connection("svc_1")["status"])
        self.assertEqual(1, view.pending_count("svc_1"))
        astore.close()

    async def test_shutdown_runs_queued_work_then_refuses_more(self):
        store = sqlite_store()
        thread = StoreThread(store, heartbeat=0)
        store_path = store.db.conn.execute("PRAGMA database_list").fetchone()["file"]
        gate = threading.Event()
        first = thread.submit(lambda: gate.wait(5))
        queued = [thread.submit(store.ensure_connection, f"svc_{n}") for n in range(5)]
        closer = threading.Thread(target=thread.close)
        closer.start()
        time.sleep(0.05)
        gate.set()
        closer.join(10)
        self.assertTrue(first.done())
        self.assertTrue(all(f.done() and f.exception() is None for f in queued))
        with self.assertRaises(Closed):
            thread.submit(store.connections)
        reopened = Store(store_path, Crypto("k" * 40))
        self.assertEqual(5, len(reopened.connections()))

    async def test_queue_wait_and_execution_are_recorded_apart(self):
        thread = StoreThread(sqlite_store(), heartbeat=0)
        thread.stats.snapshot(reset=True)
        slow = thread.submit(time.sleep, 0.2)
        fast = thread.submit(lambda: None)
        fast.result(5)
        slow.result(5)
        snap = thread.stats.snapshot()
        self.assertEqual(2, snap["jobs"])
        self.assertGreaterEqual(max(snap["run"]), 0.19, "the slow job's execution")
        self.assertGreaterEqual(max(snap["wait"]), 0.15, "the fast job waited behind it")
        self.assertLess(min(snap["run"]), 0.05, "the fast job itself was fast")
        thread.close()

    async def test_a_fatal_store_error_stops_the_process(self):
        class Lost(Exception):
            pass
        store = sqlite_store()
        store.db.fatal = (Lost,)
        recorder = Recorder()
        thread = StoreThread(store, on_fatal=recorder, heartbeat=0)

        def fails():
            raise Lost()
        with self.assertRaises(Lost):
            await thread.call(fails)
        self.assertEqual(["store_error:Lost"], recorder.reasons)
        with self.assertRaises(Closed):
            thread.submit(store.connections)

    async def test_an_ordinary_error_goes_to_the_caller_only(self):
        recorder = Recorder()
        thread = StoreThread(sqlite_store(), on_fatal=recorder, heartbeat=0)

        def fails():
            raise ValueError("a bug, not a lost connection")
        with self.assertRaises(ValueError):
            await thread.call(fails)
        self.assertEqual([], recorder.reasons)
        self.assertEqual([], await thread.call(lambda: []))
        thread.close()

    async def test_a_job_that_hangs_past_the_deadline_stops_the_process(self):
        recorder = Recorder()
        thread = StoreThread(sqlite_store(), on_fatal=recorder, op_deadline=0.3, heartbeat=10, tick=0.05)
        thread.submit(time.sleep, 2)
        self.assertTrue(await asyncio.to_thread(recorder.event.wait, 2))
        self.assertEqual(["store_stalled"], recorder.reasons)

    async def test_an_idle_store_is_pinged_and_a_failed_ping_stops_the_process(self):
        class Lost(Exception):
            pass
        store = sqlite_store()
        store.db.fatal = (Lost,)
        recorder = Recorder()
        thread = StoreThread(store, on_fatal=recorder, op_deadline=1, heartbeat=0.2, tick=0.05)
        await asyncio.sleep(0.4)
        self.assertEqual([], recorder.reasons, "pings answered")

        def lost():
            raise Lost()
        store.ping = lost
        self.assertTrue(await asyncio.to_thread(recorder.event.wait, 2))
        self.assertEqual(["store_error:Lost"], recorder.reasons)


class ShutdownTest(unittest.TestCase):
    def test_a_drain_that_does_not_finish_fails_stop_and_a_later_close_finishes(self):
        recorder = Recorder()
        store = sqlite_store()
        thread = StoreThread(store, on_fatal=recorder, op_deadline=60, heartbeat=0)
        gate = threading.Event()
        thread.submit(gate.wait, 10)
        self.assertFalse(thread.close(timeout=0.2), "did not report a finished shutdown")
        self.assertEqual(["store_close_timeout"], recorder.reasons)
        gate.set()
        self.assertTrue(thread.close(timeout=5))
        with self.assertRaises(Exception):
            store.db.execute("SELECT 1")  # closed

    def test_the_watchdog_keeps_watching_while_the_queue_drains(self):
        recorder = Recorder()
        thread = StoreThread(sqlite_store(), on_fatal=recorder, op_deadline=0.3, heartbeat=10, tick=0.05)
        thread.submit(time.sleep, 3)
        closer = threading.Thread(target=thread.close, kwargs={"timeout": 10}, daemon=True)
        closer.start()
        self.assertTrue(recorder.event.wait(2))
        self.assertEqual("store_stalled", recorder.reasons[0])


EXIT_CHILD = r"""
import logging, os, sys, threading, time
sys.path.insert(0, %(path)r)
from connector import storethread
from connector.store import Crypto, Store
handler = logging.StreamHandler(sys.stderr)
logging.getLogger().addHandler(handler)
handler.acquire()  # another thread holds the logging lock, forever
mode = sys.argv[1]
if mode == "direct":
    storethread.exit_now("store_stalled")
else:
    # The real path: the watchdog finds a stalled job and calls the default on_fatal.
    store = Store(os.path.join(%(tmp)r, "s.sqlite3"), Crypto("k" * 40))
    thread = storethread.StoreThread(store, op_deadline=0.3, heartbeat=10, tick=0.05)
    thread.submit(time.sleep, 30)
time.sleep(30)
sys.exit(3)
"""


class ExitTest(unittest.TestCase):
    def test_the_process_exits_even_when_logging_is_blocked(self):
        import subprocess
        import sys
        service = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        for mode in ("direct", "watchdog"):
            with self.subTest(mode=mode):
                script = EXIT_CHILD % {"path": service, "tmp": tempfile.mkdtemp()}
                started = time.monotonic()
                proc = subprocess.run([sys.executable, "-c", script, mode], capture_output=True, timeout=20)
                self.assertEqual(75, proc.returncode, proc.stderr[-500:])
                self.assertLess(time.monotonic() - started, 5)


class BlackHole:
    """A TCP proxy to the Postgres server that can stop forwarding while
    keeping both connections open: a server that has gone silent, not one
    that refuses (no error ever reaches the client)."""

    def __init__(self, target):
        self.target = target  # ("unix", path) or ("tcp", (host, port))
        self.swallow = threading.Event()
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen()
        self.port = self.listener.getsockname()[1]
        threading.Thread(target=self._accept, daemon=True).start()

    def _upstream(self):
        kind, address = self.target
        sock = socket.socket(socket.AF_UNIX if kind == "unix" else socket.AF_INET)
        sock.connect(address)
        return sock

    def _accept(self):
        while True:
            client, _ = self.listener.accept()
            upstream = self._upstream()
            for a, b in ((client, upstream), (upstream, client)):
                threading.Thread(target=self._pipe, args=(a, b), daemon=True).start()

    def _pipe(self, source, sink):
        try:
            while True:
                data = source.recv(65536)
                if not data:
                    return
                if self.swallow.is_set():
                    continue
                sink.sendall(data)
        except OSError:
            return


def _target_of(url):
    import psycopg
    info = psycopg.conninfo.conninfo_to_dict(url)
    host, port = info.get("host") or "localhost", int(info.get("port") or 5432)
    if host.startswith("/"):
        return ("unix", os.path.join(host, f".s.PGSQL.{port}"))
    return ("tcp", (host, port))


@pg.skip_unless_postgres
class PostgresStoreThreadTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.database = pg.Database()

    def tearDown(self):
        self.database.drop()

    def open(self, url=None, **options):
        store = Store(PostgresBackend(connect_postgres(url or self.database.url)), Crypto("k" * 40))
        recorder = Recorder()
        return store, recorder, StoreThread(store, on_fatal=recorder, **options)

    async def test_a_killed_backend_is_found_by_the_heartbeat_while_idle(self):
        _store, recorder, _thread = self.open(op_deadline=2, heartbeat=0.3, tick=0.05)
        await asyncio.sleep(0.2)
        self.assertGreaterEqual(self.database.terminate_connections(), 1)
        self.assertTrue(await asyncio.to_thread(recorder.event.wait, 5))
        self.assertTrue(recorder.reasons[0].startswith("store_error:"), recorder.reasons)

    async def test_a_silent_server_is_found_by_the_watchdog(self):
        import psycopg
        hole = BlackHole(_target_of(self.database.url))
        info = psycopg.conninfo.conninfo_to_dict(self.database.url)
        info.update(host="127.0.0.1", port=str(hole.port))
        url = psycopg.conninfo.make_conninfo(**info)
        store, recorder, thread = self.open(url, op_deadline=1.0, heartbeat=0.3, tick=0.05)
        await thread.call(store.ensure_connection, "svc_1")
        hole.swallow.set()
        started = time.monotonic()
        # Idle: the heartbeat's ping goes unanswered; nothing errors.
        self.assertTrue(await asyncio.to_thread(recorder.event.wait, 5))
        self.assertEqual("store_stalled", recorder.reasons[0])
        self.assertLess(time.monotonic() - started, 0.3 + 0.05 + 1.0 + 0.5)

    async def test_the_advisory_lock_is_held_by_one_connection_at_a_time(self):
        first = PostgresBackend(connect_postgres(self.database.url))
        second = PostgresBackend(connect_postgres(self.database.url))
        self.assertTrue(first.try_advisory_lock())
        self.assertFalse(second.try_advisory_lock())
        first.close()
        await asyncio.sleep(0.1)
        self.assertTrue(second.try_advisory_lock())
        second.close()

    async def test_the_schema_records_its_version_and_refuses_a_newer_one(self):
        from connector.store import SCHEMA_VERSION, SchemaTooNew
        backend = PostgresBackend(connect_postgres(self.database.url))
        backend.conn.execute("UPDATE schema_version SET version = %s", (SCHEMA_VERSION + 1,))
        backend.close()
        with self.assertRaises(SchemaTooNew):
            PostgresBackend(connect_postgres(self.database.url))


if __name__ == "__main__":
    unittest.main()
