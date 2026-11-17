"""The real connector process on Postgres (COMMS_STORE=postgres): every
ProcessTest again, plus what only Postgres has: the database lock across
volumes, fail-stop when the store connection is lost, and the refusal to
start on a volume that was never migrated."""

import asyncio
import os
import socket

from tests import pg
from tests.helpers import wait_for
from tests.test_process import ProcessTest, free_port


@pg.skip_unless_postgres
class PostgresProcessTest(ProcessTest):
    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.database = pg.Database()

    async def asyncTearDown(self):
        await super().asyncTearDown()
        self.database.drop()

    def env(self, **overrides):
        env = super().env(**overrides)
        env["COMMS_STORE"] = overrides.get("COMMS_STORE") or "postgres"
        env["COMMS_DATABASE_URL"] = self.database.url
        return env

    def database_dump(self):
        import psycopg
        lines = []
        with psycopg.connect(self.database.url) as conn:
            for table in ("connections", "outbox", "carryover", "chats", "channels", "peer_messages"):
                for row in conn.execute(f"SELECT * FROM {table}").fetchall():
                    lines.append(repr(row))
        return "\n".join(lines)

    async def test_two_step_password_never_reaches_the_log_or_the_store(self):
        await super().test_two_step_password_never_reaches_the_log_or_the_store()
        dump = self.database_dump()
        self.assertTrue(dump, "the database holds the connection")
        self.assertNotIn("PASSWORD-CANARY", dump)
        from tests.test_process import CANARY
        self.assertNotIn(CANARY, dump, "message content sealed in the database too")

    async def test_a_process_on_another_volume_waits_for_the_database_lock(self):
        first = await self.spawn(TELEGRAM_FAKE_LIVE="30", TELEGRAM_FAKE_LIVE_INTERVAL="0.5")
        await self.listening()
        await self.connect_account()
        other = os.path.join(self.dir, "other-volume")
        os.mkdir(other)
        second_port = free_port()
        second = await self.spawn(port=second_port, COMMS_DATA_DIR=other,
                                  TELEGRAM_FAKE_LIVE="30", TELEGRAM_FAKE_LIVE_INTERVAL="0.5")
        await wait_for(lambda: "waiting for the database lock" in self.read_log(), timeout=10)
        await asyncio.sleep(1.0)
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", second_port), timeout=0.2).close()
        self.assertEqual(1, self.read_log().count('"msg": "started"'))
        first.kill()
        await first.wait()
        await self.listening(timeout=15)
        await wait_for(lambda: self.read_log().count('"msg": "started"') == 2, timeout=15)
        self.assertIsNone(second.returncode)

    async def test_losing_the_store_connection_ends_the_process(self):
        proc = await self.spawn(TELEGRAM_FAKE_LIVE="60", TELEGRAM_FAKE_LIVE_INTERVAL="0.5")
        await self.listening()
        await self.connect_account()
        await wait_for(lambda: len(self.live()) >= 2, timeout=15)
        self.assertGreaterEqual(self.database.terminate_connections(), 1)
        # Detected by the next store call or, idle, by the heartbeat (5 s);
        # bound in README "Store": heartbeat + tick + op deadline.
        self.assertEqual(75, await asyncio.wait_for(proc.wait(), 20))
        self.assertIn("store lost; exiting", self.read_log())

    async def test_refuses_a_volume_that_was_never_migrated(self):
        open(os.path.join(self.data, "telegram.sqlite3"), "wb").close()
        proc = await self.spawn()
        self.assertEqual(2, await asyncio.wait_for(proc.wait(), 10))
        self.assertIn("startup refused: reason=unmigrated_sqlite_store", self.read_log())
        os.remove(os.path.join(self.data, "telegram.sqlite3"))
        open(os.path.join(self.data, ".lease"), "wb").close()
        proc = await self.spawn()
        self.assertEqual(2, await asyncio.wait_for(proc.wait(), 10))
        self.assertIn("startup refused: reason=pre_migration_lock_file", self.read_log())

    async def test_refuses_sqlite_with_the_real_provider(self):
        proc = await self.spawn(COMMS_STORE="sqlite", TELEGRAM_PROVIDER="telethon",
                                TELEGRAM_API_ID="1", TELEGRAM_API_HASH="h" * 32)
        self.assertEqual(2, await asyncio.wait_for(proc.wait(), 10))
        self.assertIn("startup refused: reason=sqlite_store_needs_fake", self.read_log())


del ProcessTest  # not collected twice from this module
