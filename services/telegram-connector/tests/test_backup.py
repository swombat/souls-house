"""connector.backup: a sealed dump of the live database, and a restore that
commits nothing unless every check passes. Test key only: this proves the
fixture path, not a production restore."""

import fcntl
import io
import json
import os
import struct
import tempfile
import unittest
from unittest import mock

from connector import backup, migrate
from connector.store import TABLES, Crypto, PostgresBackend, Store, connect_postgres
from tests import pg
from tests.test_migrate import KEY, populate


def sqlite_to_postgres_fixture(database):
    """The migration's fixture (every table, sealed columns, a carryover),
    moved into `database` the way production gets there."""
    data = tempfile.mkdtemp(prefix="tg-backup-src-")
    populate(os.path.join(data, "telegram.sqlite3"))
    with open(os.devnull, "w") as quiet:
        import contextlib
        with contextlib.redirect_stdout(quiet):
            assert migrate.main(["sqlite-to-postgres", "--data-dir", data],
                                env={"COMMS_DATABASE_URL": database.url}) == 0
    return data


def contents(url):
    conn = connect_postgres(url)
    try:
        return migrate.read_all(PostgresBackend(conn).execute)
    finally:
        conn.close()


def empty(url):
    return all(not rows for rows in contents(url).values())


@pg.skip_unless_postgres
class BackupTest(unittest.TestCase):
    def setUp(self):
        self.source = pg.Database()
        self.target = pg.Database()
        sqlite_to_postgres_fixture(self.source)
        self.volume = tempfile.mkdtemp(prefix="tg-backup-dst-")  # a fresh volume

    def tearDown(self):
        self.source.drop()
        self.target.drop()

    def dump(self, chunk_size=backup.CHUNK_SIZE, key=KEY):
        out = io.BytesIO()
        backup.dump(self.source.url, key, out, chunk_size=chunk_size)
        return out.getvalue()

    def restore(self, data, key=KEY):
        return backup.restore(self.volume, self.target.url, key, io.BytesIO(data))

    def test_round_trip_is_byte_for_byte_and_locks_the_old_image_out(self):
        result = self.restore(self.dump(chunk_size=300))  # many chunks
        self.assertEqual(2, result["connections"])
        migrate.compare(contents(self.source.url), contents(self.target.url))
        store = Store(PostgresBackend(connect_postgres(self.target.url)), Crypto(KEY))
        self.assertEqual("SESSION-svc_1", store.session("svc_1"))
        # The carryover generator continues past the restored rows.
        before = max(row["ord"] for row in migrate.read_all(store.db.execute)["carryover"])
        store.db.execute("INSERT INTO carryover (ref, body) VALUES (?, ?)", ("svc_1", b"x"))
        after = max(row["ord"] for row in migrate.read_all(store.db.execute)["carryover"])
        self.assertGreater(after, before)
        store.db.close()
        self.assertTrue(os.path.isdir(os.path.join(self.volume, ".lease")))

    def test_dump_carries_no_plaintext(self):
        data = self.dump()
        header_len = struct.unpack(">I", data[9:13])[0]
        sealed = data[13 + header_len:]
        for secret in (b"SESSION-svc_1", b"secret-svc_1", b"m4-svc_1", b"svc_1", b"user:42", b"connections"):
            self.assertNotIn(secret, sealed)
        # The header names refs and counts only: no sealed value, no message.
        header, _ = backup.read_header(io.BytesIO(data))
        self.assertNotIn("SESSION", json.dumps(header))
        self.assertEqual(7, len(header["counts"]))

    def test_dump_runs_beside_the_live_connector(self):
        holder = connect_postgres(self.source.url)
        try:
            self.assertTrue(PostgresBackend(holder).try_advisory_lock())
            self.assertTrue(backup.verify(io.BytesIO(self.dump()), KEY)["tables"]["outbox"] > 0)
        finally:
            holder.close()

    def assert_refused_and_empty(self, data, reason, key=KEY):
        with self.assertRaises(backup.Invalid) as caught:
            self.restore(data, key)
        self.assertTrue(str(caught.exception).startswith(reason), str(caught.exception))
        self.assertTrue(empty(self.target.url))
        self.assertFalse(os.path.isdir(os.path.join(self.volume, ".lease")))

    def test_wrong_key_fails_closed(self):
        self.assert_refused_and_empty(self.dump(), "tag", key="w" * 40)

    def test_tampered_header_fails_closed(self):
        data = bytearray(self.dump())
        at = data.index(b'"created_at":') + len(b'"created_at":')
        data[at] = ord("9") if data[at] != ord("9") else ord("8")
        self.assert_refused_and_empty(bytes(data), "tag")

    def test_tampered_body_fails_closed_after_earlier_chunks_were_imported(self):
        data = bytearray(self.dump(chunk_size=300))
        data[-20] ^= 1  # inside the final chunk: earlier chunks are already inserted
        self.assert_refused_and_empty(bytes(data), "tag")

    def test_truncation_and_trailing_data_fail_closed(self):
        data = self.dump(chunk_size=300)
        # Drop the final chunk: find the chunk boundaries from the front.
        header_len = struct.unpack(">I", data[9:13])[0]
        offset, starts = 13 + header_len, []
        while offset < len(data):
            starts.append(offset)
            (length,) = struct.unpack(">I", data[offset:offset + 4])
            offset += 4 + length
        self.assert_refused_and_empty(data[:starts[-1]], "truncated")
        self.assert_refused_and_empty(data[:-1], "truncated")
        self.assert_refused_and_empty(data + b"\0", "trailing_data")

    def test_newer_format_or_schema_is_refused(self):
        data = bytearray(self.dump())
        data[len(backup.MAGIC)] = 2
        self.assert_refused_and_empty(bytes(data), "format")
        current = self.dump()  # a dump at version 1, read by an image expecting 2
        with mock.patch.object(backup, "SCHEMA_VERSION", 2):
            self.assert_refused_and_empty(current, "schema_version")

    def test_a_failed_read_back_rolls_everything_back(self):
        with mock.patch.object(backup, "_check_readback", side_effect=backup.Invalid("readback:outbox")):
            self.assert_refused_and_empty(self.dump(), "readback")

    def test_refuses_a_database_with_any_connector_row(self):
        conn = connect_postgres(self.target.url)
        PostgresBackend(conn).execute("INSERT INTO command_nonces (command_id, seen_at) VALUES (?, ?)", ("n", 1.0))
        conn.close()
        with self.assertRaises(migrate.Refused) as caught:
            self.restore(self.dump())
        self.assertEqual("database_not_empty:command_nonces", str(caught.exception))

    def test_refuses_while_the_connector_holds_the_volume(self):
        fd = os.open(os.path.join(self.volume, ".owner"), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            with self.assertRaises(migrate.Refused) as caught:
                self.restore(self.dump())
            self.assertEqual("connector_running", str(caught.exception))
        finally:
            os.close(fd)
        self.assertTrue(empty(self.target.url))

    def test_refuses_an_unmigrated_volume(self):
        open(os.path.join(self.volume, "telegram.sqlite3"), "w").close()
        with self.assertRaises(migrate.Refused):
            self.restore(self.dump())

    def test_command_line_keeps_stdout_for_ciphertext_and_names_no_dsn(self):
        out, err = io.BytesIO(), io.StringIO()
        env = {"COMMS_DATABASE_URL": self.source.url, "COMMS_STORE_KEY": KEY}
        self.assertEqual(0, backup.main(["dump"], env=env, stdout=out, stderr=err))
        self.assertTrue(out.getvalue().startswith(backup.MAGIC))
        self.assertEqual("dump", json.loads(err.getvalue())["done"])
        bad, err = io.BytesIO(), io.StringIO()
        env = {"COMMS_DATABASE_URL": "postgresql://u:hunter2@127.0.0.1:1/x", "COMMS_STORE_KEY": KEY}
        self.assertEqual(1, backup.main(["dump"], env=env, stdout=bad, stderr=err))
        self.assertEqual(b"", bad.getvalue())
        self.assertNotIn("hunter2", err.getvalue())
        err = io.StringIO()
        env = {"COMMS_DATABASE_URL": self.target.url, "COMMS_STORE_KEY": KEY}
        self.assertEqual(0, backup.main(["restore", "--data-dir", self.volume], env=env,
                                        stdin=io.BytesIO(out.getvalue()), stderr=err))
        migrate.compare(contents(self.source.url), contents(self.target.url))


if __name__ == "__main__":
    unittest.main()
