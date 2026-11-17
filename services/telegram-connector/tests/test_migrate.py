"""connector.migrate: SQLite to Postgres and back, verified, with the
volume and database locks held and the old image locked out."""

import fcntl
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout

from connector import migrate
from connector.lease import Lease
from connector.store import NOOP_EVENT, Crypto, PostgresBackend, Store, connect_postgres
from tests import pg

KEY = "m" * 40


def populate(path):
    """A store with something in every table, including sealed columns, a
    delivered and an undelivered outbox, a carryover and 64-bit ids."""
    store = Store(path, Crypto(KEY))
    for ref in ("svc_1", "svc_2"):
        store.ensure_connection(ref)
        store.set_callback_secret(ref, f"secret-{ref}-" + "x" * 40, 3)
        store.set_session(ref, f"SESSION-{ref}")
        store.update_connection(ref, status="connected", generation=4, self_id=2**40 + 7,
                                pts=123456, qts=9, date=1763370000)
        with store.transaction():
            for n in range(5):
                store.enqueue(ref, {"type": "message.upsert", "messages": [{"body": f"m{n}-{ref}"}]})
        store.mark_delivered(ref, 2)
        store.upsert_chat(ref, "user:42", True, "direct", None)
        store.upsert_chat(ref, "channel:1000000000123", True, "group", 512)
        store.set_backfill(ref, "user:42", 99, 7, False, "2026-10-01T00:00:00Z")
        store.set_channel_pts(ref, 1000000000123, 2**33)
        store.remember_peer(ref, 77, "user:42")
    store.set_aside_pending("svc_2", lambda event: event.get("type") == "message.upsert")
    store.consume_command_id("c" * 32, 1763370000.25, 180)
    store.db.close()


@pg.skip_unless_postgres
class MigrateTest(unittest.TestCase):
    def setUp(self):
        self.database = pg.Database()
        self.data = tempfile.mkdtemp(prefix="tg-migrate-")
        self.sqlite = os.path.join(self.data, "telegram.sqlite3")
        populate(self.sqlite)
        open(os.path.join(self.data, ".lease"), "a").close()  # the old image's lock file

    def tearDown(self):
        self.database.drop()

    def run_command(self, *argv):
        out = io.StringIO()
        with redirect_stdout(out):
            code = migrate.main(list(argv) + ["--data-dir", self.data],
                                env={"COMMS_DATABASE_URL": self.database.url})
        return code, json.loads(out.getvalue())

    def postgres_store(self):
        return Store(PostgresBackend(connect_postgres(self.database.url)), Crypto(KEY))

    def test_moves_every_row_and_locks_the_old_image_out(self):
        before = Store(self.sqlite, Crypto(KEY))
        expected = migrate.read_all(before.db.execute)
        before.db.close()
        code, result = self.run_command("sqlite-to-postgres")
        self.assertEqual(0, code, result)
        self.assertEqual(4, result["connections"]["svc_1"]["next_seq"] - 2)
        self.assertTrue(result["copied"])
        store = self.postgres_store()
        migrate.compare(expected, migrate.read_all(store.db.execute))
        # Sealed columns open with the same key; nothing was decrypted on the way.
        self.assertEqual("SESSION-svc_1", store.session("svc_1"))
        self.assertEqual(["m2-svc_1", "m3-svc_1", "m4-svc_1"],
                         [json.loads(r["body"])["messages"][0]["body"] for r in store.pending("svc_1")])
        # The sequence and the carryover continue where they were.
        with store.transaction():
            self.assertEqual(6, store.enqueue("svc_1", NOOP_EVENT))
            self.assertEqual(3, store.take_carryover("svc_2"))  # its three undelivered rows
        self.assertFalse(store.consume_command_id("c" * 32, 1763370001, 180), "replay protection carried over")
        store.db.close()
        # The source is kept, renamed; the old image's lock is a directory now.
        self.assertFalse(os.path.exists(self.sqlite))
        self.assertTrue(os.path.exists(os.path.join(self.data, result["source_kept"])))
        self.assertTrue(os.path.isdir(os.path.join(self.data, ".lease")))
        with self.assertRaises(OSError):
            Lease(self.data).try_acquire()  # what the pre-migration image does first

    def test_the_old_image_cannot_take_the_lock_at_any_point_of_the_cutover(self):
        """Mira's #1011 finding: a rename then a mkdir left `.lease` free in
        between. An old-image process polls for the lock through the whole
        cutover (each step widened); the path must never be free and the
        lock never obtainable."""
        import threading
        import time as _time
        lease = os.path.join(self.data, ".lease")
        stop, won, seen = threading.Event(), [], []

        def old_image():
            while not stop.is_set():
                try:
                    Lease(self.data).try_acquire()
                    won.append(True)
                    return
                except Exception:
                    pass

        poller = threading.Thread(target=old_image)

        def probe(step):
            if step == "locked":
                poller.start()  # from the moment the migration holds the volume
            seen.append((step, os.path.lexists(lease), os.path.isdir(lease)))
            _time.sleep(0.2)
        migrate.PROBE = probe
        try:
            code, result = self.run_command("sqlite-to-postgres")
        finally:
            migrate.PROBE = None
            stop.set()
            if poller.is_alive():
                poller.join(5)
        self.assertEqual(0, code, result)
        self.assertEqual([], won, "the old image took the lock during the cutover")
        self.assertEqual(["locked", "replacement_ready", "lease_swapped", "source_renamed"], [s[0] for s in seen])
        self.assertTrue(all(exists for _step, exists, _dir in seen), "the lock path was free at some step")
        self.assertEqual([False, False, True, True], [is_dir for _step, _exists, is_dir in seen])

    def test_without_an_atomic_exchange_the_cutover_refuses_before_anything_moves(self):
        def cannot(_a, _b):
            raise OSError(22, "Invalid argument")
        original = migrate.exchange
        migrate.exchange = cannot
        try:
            code, result = self.run_command("sqlite-to-postgres")
        finally:
            migrate.exchange = original
        self.assertEqual((2, {"refused": "cutover_needs_atomic_exchange"}), (code, result))
        self.assertTrue(os.path.isfile(os.path.join(self.data, ".lease")))
        self.assertTrue(os.path.exists(self.sqlite))
        self.assertEqual([], [n for n in os.listdir(self.data) if n.startswith(".lease.next-")])

    def test_refuses_while_a_connector_holds_the_volume(self):
        for name, reason in ((".lease", "old_connector_running"), (".owner", "connector_running")):
            fd = os.open(os.path.join(self.data, name), os.O_RDWR | os.O_CREAT)
            fcntl.flock(fd, fcntl.LOCK_EX)
            try:
                code, result = self.run_command("sqlite-to-postgres")
            finally:
                os.close(fd)
            self.assertEqual((2, {"refused": reason}), (code, result))
        self.assertTrue(os.path.exists(self.sqlite))

    def test_refuses_while_a_connector_holds_the_database(self):
        holder = PostgresBackend(connect_postgres(self.database.url))
        self.assertTrue(holder.try_advisory_lock())
        try:
            self.assertEqual((2, {"refused": "database_locked"}), self.run_command("sqlite-to-postgres"))
        finally:
            holder.close()

    def test_refuses_a_destination_that_holds_something_else(self):
        store = self.postgres_store()
        store.ensure_connection("svc_9")
        store.db.close()
        code, result = self.run_command("sqlite-to-postgres")
        self.assertEqual(2, code)
        self.assertTrue(result["refused"].startswith("verify_failed:connections"), result)
        self.assertTrue(os.path.exists(self.sqlite), "source untouched")
        self.assertTrue(os.path.isfile(os.path.join(self.data, ".lease")))

    def test_a_rerun_finishes_an_interrupted_cutover(self):
        code, _ = self.run_command("sqlite-to-postgres")
        self.assertEqual(0, code)
        # As if it stopped after the lock swap and before the rename.
        kept = [n for n in os.listdir(self.data) if n.startswith("telegram.sqlite3.migrated-")]
        os.rename(os.path.join(self.data, kept[0]), self.sqlite)
        code, result = self.run_command("sqlite-to-postgres")
        self.assertEqual(0, code, result)
        self.assertFalse(result["copied"])
        self.assertFalse(os.path.exists(self.sqlite))

    def test_rollback_restores_a_verified_sqlite_store_and_the_old_lock(self):
        self.assertEqual(0, self.run_command("sqlite-to-postgres")[0])
        store = self.postgres_store()
        with store.transaction():
            store.enqueue("svc_1", {"type": "message.upsert", "messages": [{"body": "after the move"}]})
        expected = migrate.read_all(store.db.execute)
        store.db.close()
        code, result = self.run_command("postgres-to-sqlite")
        self.assertEqual(0, code, result)
        restored = Store(self.sqlite, Crypto(KEY))
        migrate.compare(expected, migrate.read_all(restored.db.execute))
        restored.db.close()
        self.assertTrue(os.path.isfile(os.path.join(self.data, ".lease")))
        self.assertEqual((2, {"refused": "destination_exists"}), self.run_command("postgres-to-sqlite"))
        # Migrating again needs the stale copy emptied first, explicitly.
        code, result = self.run_command("sqlite-to-postgres")
        self.assertEqual(0, code, "the database copy still equals the restored store")
        self.assertFalse(result["copied"])

    def test_empty_postgres_needs_confirmation_and_a_rolled_back_volume(self):
        self.assertEqual(2, self.run_command("empty-postgres")[0])
        self.assertEqual(0, self.run_command("sqlite-to-postgres")[0])
        self.assertEqual((2, {"refused": "no_sqlite_store"}),
                         self.run_command("empty-postgres", "--yes-delete-the-postgres-copy"))
        self.assertEqual(0, self.run_command("postgres-to-sqlite")[0])
        code, result = self.run_command("empty-postgres", "--yes-delete-the-postgres-copy")
        self.assertEqual(0, code, result)
        self.assertEqual(2, result["deleted"]["connections"])
        store = self.postgres_store()
        self.assertEqual([], store.connections())
        store.db.close()


if __name__ == "__main__":
    unittest.main()
