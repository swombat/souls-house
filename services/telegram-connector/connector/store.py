"""The connector's own store: SQLite on the connector's volume.

S2a runs one connector process, so a single SQLite file is the whole store.
Secret columns (the Telegram session, the callback secret) are AES-GCM under
a key derived per connection from COMMS_STORE_KEY, so the file alone (or a
backup of it) gives nobody a Telegram login.

Update state (pts/qts/date and per-channel pts) is only ever written in the
same transaction as the outbox rows derived from it (proposal §5a): if the
process dies before that commit, Telegram replays the same updates.
"""

import json
import os
import sqlite3
import time

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

SCHEMA = """
CREATE TABLE IF NOT EXISTS connections (
  ref TEXT PRIMARY KEY,
  generation INTEGER NOT NULL DEFAULT 0,
  secret_version INTEGER NOT NULL DEFAULT 0,
  callback_secret BLOB,
  session BLOB,
  status TEXT NOT NULL DEFAULT 'new',
  identity TEXT,
  pts INTEGER, qts INTEGER, date INTEGER,
  self_id INTEGER,
  next_seq INTEGER NOT NULL DEFAULT 1,
  seq_known INTEGER NOT NULL DEFAULT 0,
  updated_at REAL
);
CREATE TABLE IF NOT EXISTS chats (
  ref TEXT NOT NULL, chat TEXT NOT NULL,
  synced INTEGER NOT NULL, kind TEXT,
  participants INTEGER,
  backfill_offset INTEGER, backfill_count INTEGER NOT NULL DEFAULT 0,
  backfill_done INTEGER NOT NULL DEFAULT 0, history_from TEXT,
  PRIMARY KEY (ref, chat)
);
CREATE TABLE IF NOT EXISTS carryover (
  ref TEXT NOT NULL, ord INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS channels (
  ref TEXT NOT NULL, channel_id INTEGER NOT NULL, pts INTEGER NOT NULL,
  PRIMARY KEY (ref, channel_id)
);
CREATE TABLE IF NOT EXISTS peer_messages (
  ref TEXT NOT NULL, message_id INTEGER NOT NULL, chat TEXT NOT NULL,
  PRIMARY KEY (ref, message_id)
);
CREATE TABLE IF NOT EXISTS outbox (
  ref TEXT NOT NULL, seq INTEGER NOT NULL, body TEXT NOT NULL,
  delivered INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL,
  PRIMARY KEY (ref, seq)
);
CREATE INDEX IF NOT EXISTS outbox_pending ON outbox (ref, delivered, seq);
CREATE TABLE IF NOT EXISTS command_nonces (
  command_id TEXT PRIMARY KEY, seen_at REAL NOT NULL
);
"""


# Occupies an outbox sequence number without changing anything Rails shows:
# Rails applies connector.availability in any connection state.
NOOP_EVENT = {"type": "connector.availability", "state": "ok"}


def encode(event):
    return json.dumps(event, separators=(",", ":"), ensure_ascii=False)


class Crypto:
    """AES-GCM per connection: key = HKDF-SHA256(COMMS_STORE_KEY, info=ref)."""

    def __init__(self, master_key):
        if not master_key or len(master_key) < 32:
            raise ValueError("COMMS_STORE_KEY must be at least 32 characters")
        self._master = master_key.encode() if isinstance(master_key, str) else master_key

    def _key(self, ref):
        return HKDF(algorithm=hashes.SHA256(), length=32, salt=b"souls-house-telegram-store-v1",
                    info=ref.encode()).derive(self._master)

    def seal(self, ref, plaintext):
        if plaintext is None:
            return None
        nonce = os.urandom(12)
        data = plaintext.encode() if isinstance(plaintext, str) else plaintext
        return nonce + AESGCM(self._key(ref)).encrypt(nonce, data, ref.encode())

    def open(self, ref, sealed):
        if sealed is None:
            return None
        return AESGCM(self._key(ref)).decrypt(sealed[:12], sealed[12:], ref.encode()).decode()


class Store:
    def __init__(self, path, crypto):
        self.crypto = crypto
        # Tests and the fake-provider e2e set this to inject a crash at a
        # named point (see faults()). Never set in production.
        self.fault = None
        self.db = sqlite3.connect(path, isolation_level=None, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript(SCHEMA)

    # -- transactions -------------------------------------------------------

    def transaction(self):
        return _Transaction(self.db)

    def checkpoint(self, name):
        """A named point inside the ingest path where a test can crash the
        process (or raise, which rolls the transaction back)."""
        if self.fault:
            self.fault(name)

    # -- connections --------------------------------------------------------

    def connection(self, ref):
        return self.db.execute("SELECT * FROM connections WHERE ref = ?", (ref,)).fetchone()

    def connections(self):
        return self.db.execute("SELECT * FROM connections ORDER BY ref").fetchall()

    def ensure_connection(self, ref):
        self.db.execute("INSERT OR IGNORE INTO connections (ref, updated_at) VALUES (?, ?)", (ref, time.time()))
        return self.connection(ref)

    def update_connection(self, ref, **fields):
        if not fields:
            return
        fields["updated_at"] = time.time()
        columns = ", ".join(f"{name} = ?" for name in fields)
        self.db.execute(f"UPDATE connections SET {columns} WHERE ref = ?", (*fields.values(), ref))

    def callback_secret(self, ref):
        row = self.connection(ref)
        return row and self.crypto.open(ref, row["callback_secret"])

    def set_callback_secret(self, ref, secret, version):
        """Never installs a lower version than the one held (proposal §5)."""
        row = self.ensure_connection(ref)
        if version < row["secret_version"]:
            return False
        self.update_connection(ref, callback_secret=self.crypto.seal(ref, secret), secret_version=version)
        return True

    def session(self, ref):
        row = self.connection(ref)
        return row and self.crypto.open(ref, row["session"])

    def set_session(self, ref, session_string):
        self.update_connection(ref, session=self.crypto.seal(ref, session_string))

    def delete_connection(self, ref):
        with self.transaction():
            for table in ("connections", "channels", "peer_messages", "outbox", "chats", "carryover"):
                self.db.execute(f"DELETE FROM {table} WHERE ref = ?", (ref,))

    def wipe_sync_state(self, ref):
        """Forgets everything about the account a session belonged to: update
        state, channels, peer map, chats. Keeps the outbox and the sequence."""
        self.db.execute("UPDATE connections SET pts = NULL, qts = NULL, date = NULL, self_id = NULL, "
                        "session = NULL, identity = NULL WHERE ref = ?", (ref,))
        for table in ("channels", "peer_messages", "chats"):
            self.db.execute(f"DELETE FROM {table} WHERE ref = ?", (ref,))

    # -- chats (scope and backfill progress) ----------------------------------

    def chat(self, ref, chat):
        return self.db.execute("SELECT * FROM chats WHERE ref = ? AND chat = ?", (ref, chat)).fetchone()

    def chats(self, ref, synced=None):
        if synced is None:
            return self.db.execute("SELECT * FROM chats WHERE ref = ? ORDER BY chat", (ref,)).fetchall()
        return self.db.execute("SELECT * FROM chats WHERE ref = ? AND synced = ? ORDER BY chat",
                               (ref, 1 if synced else 0)).fetchall()

    def upsert_chat(self, ref, chat, synced, kind, participants=None):
        self.db.execute(
            "INSERT INTO chats (ref, chat, synced, kind, participants) VALUES (?, ?, ?, ?, ?) "
            "ON CONFLICT (ref, chat) DO UPDATE SET synced = excluded.synced, kind = excluded.kind, "
            "participants = COALESCE(excluded.participants, chats.participants)",
            (ref, chat, 1 if synced else 0, kind, participants),
        )

    def pending_backfill(self, ref):
        return self.db.execute("SELECT * FROM chats WHERE ref = ? AND synced = 1 AND backfill_done = 0 ORDER BY chat",
                               (ref,)).fetchall()

    def set_backfill(self, ref, chat, offset, count, done, history_from=None):
        self.db.execute("UPDATE chats SET backfill_offset = ?, backfill_count = ?, backfill_done = ?, "
                        "history_from = COALESCE(?, history_from) WHERE ref = ? AND chat = ?",
                        (offset, count, 1 if done else 0, history_from, ref, chat))

    def restart_backfill(self, ref, chats=None):
        """After a gap Telegram will not replay (a difference too long), the
        history of the affected chats is fetched again (bounded as before)."""
        if chats is None:
            self.db.execute("UPDATE chats SET backfill_offset = NULL, backfill_count = 0, backfill_done = 0 "
                            "WHERE ref = ? AND synced = 1", (ref,))
        else:
            for chat in chats:
                self.db.execute("UPDATE chats SET backfill_offset = NULL, backfill_count = 0, backfill_done = 0 "
                                "WHERE ref = ? AND chat = ? AND synced = 1", (ref, chat))

    # -- update state (only inside a transaction with the outbox rows) -------

    def channel_pts(self, ref):
        rows = self.db.execute("SELECT channel_id, pts FROM channels WHERE ref = ?", (ref,)).fetchall()
        return {row["channel_id"]: row["pts"] for row in rows}

    def set_channel_pts(self, ref, channel_id, pts):
        self.db.execute(
            "INSERT INTO channels (ref, channel_id, pts) VALUES (?, ?, ?) "
            "ON CONFLICT (ref, channel_id) DO UPDATE SET pts = excluded.pts",
            (ref, channel_id, pts),
        )

    def remember_peer(self, ref, message_id, chat):
        self.db.execute("INSERT OR REPLACE INTO peer_messages (ref, message_id, chat) VALUES (?, ?, ?)",
                        (ref, message_id, chat))

    def peer_of(self, ref, message_id):
        row = self.db.execute("SELECT chat FROM peer_messages WHERE ref = ? AND message_id = ?",
                              (ref, message_id)).fetchone()
        return row and row["chat"]

    # -- outbox -------------------------------------------------------------

    def enqueue(self, ref, event):
        """Appends one event with the connection's next sequence number."""
        row = self.connection(ref)
        seq = row["next_seq"]
        event = dict(event, seq=seq)
        self.db.execute("INSERT INTO outbox (ref, seq, body, created_at) VALUES (?, ?, ?, ?)",
                        (ref, seq, encode(event), time.time()))
        self.db.execute("UPDATE connections SET next_seq = ? WHERE ref = ?", (seq + 1, ref))
        return seq

    def replace_pending(self, ref, seq, event):
        """Rewrites one undelivered row in place, keeping its sequence number
        (Rails needs the sequence without holes)."""
        self.db.execute("UPDATE outbox SET body = ? WHERE ref = ? AND seq = ? AND delivered = 0",
                        (encode(dict(event, seq=seq)), ref, seq))

    def set_aside_pending(self, ref, keep):
        """A new login attempt: Rails will refuse the old session's chats and
        messages until the new one is connected, and would block the attempt's
        own events behind them. Every undelivered row becomes a no-op in place
        (so the sequence keeps no holes); those `keep(event)` selects are
        copied to the carryover, to be queued again after `connected`."""
        with self.transaction():
            for row in self.db.execute("SELECT seq, body FROM outbox WHERE ref = ? AND delivered = 0 ORDER BY seq",
                                       (ref,)).fetchall():
                event = json.loads(row["body"])
                if keep(event):
                    event.pop("seq", None)
                    self.db.execute("INSERT INTO carryover (ref, body) VALUES (?, ?)", (ref, encode(event)))
                self.replace_pending(ref, row["seq"], NOOP_EVENT)

    def take_carryover(self, ref):
        """Moves the carryover back into the outbox (call inside a transaction)."""
        rows = self.db.execute("SELECT ord, body FROM carryover WHERE ref = ? ORDER BY ord", (ref,)).fetchall()
        for row in rows:
            self.enqueue(ref, json.loads(row["body"]))
        self.db.execute("DELETE FROM carryover WHERE ref = ?", (ref,))
        return len(rows)

    def renumber(self, ref, committed):
        """A store that started its sequence at 1 learns Rails has committed up
        to `committed` for this connection (a fresh store for a connection
        Rails already knows): every row moves past it."""
        with self.transaction():
            rows = self.db.execute("SELECT seq, body FROM outbox WHERE ref = ? ORDER BY seq DESC", (ref,)).fetchall()
            for row in rows:
                event = json.loads(row["body"])
                event["seq"] = row["seq"] + committed
                self.db.execute("UPDATE outbox SET seq = ?, body = ? WHERE ref = ? AND seq = ?",
                                (row["seq"] + committed, encode(event), ref, row["seq"]))
            self.db.execute("UPDATE connections SET next_seq = next_seq + ?, seq_known = 1 WHERE ref = ?",
                            (committed, ref))

    def pending(self, ref, limit=50):
        return self.db.execute(
            "SELECT seq, body FROM outbox WHERE ref = ? AND delivered = 0 ORDER BY seq LIMIT ?", (ref, limit)
        ).fetchall()

    def pending_count(self, ref):
        return self.db.execute("SELECT COUNT(*) FROM outbox WHERE ref = ? AND delivered = 0", (ref,)).fetchone()[0]

    def oldest_pending_age(self, ref):
        row = self.db.execute("SELECT MIN(created_at) FROM outbox WHERE ref = ? AND delivered = 0", (ref,)).fetchone()
        return row[0] and time.time() - row[0]

    def mark_delivered(self, ref, through_seq):
        self.db.execute("UPDATE outbox SET delivered = 1 WHERE ref = ? AND seq <= ? AND delivered = 0",
                        (ref, through_seq))
        # Delivered rows are kept a day for diagnosis, then dropped.
        self.db.execute("DELETE FROM outbox WHERE ref = ? AND delivered = 1 AND created_at < ?",
                        (ref, time.time() - 86400))

    # -- command replay protection ------------------------------------------

    def consume_command_id(self, command_id, now, retention):
        self.db.execute("DELETE FROM command_nonces WHERE seen_at < ?", (now - retention,))
        try:
            self.db.execute("INSERT INTO command_nonces (command_id, seen_at) VALUES (?, ?)", (command_id, now))
            return True
        except sqlite3.IntegrityError:
            return False


class _Transaction:
    def __init__(self, db):
        self.db = db

    def __enter__(self):
        self.db.execute("BEGIN IMMEDIATE")
        return self

    def __exit__(self, exc_type, exc, tb):
        self.db.execute("ROLLBACK" if exc_type else "COMMIT")
        return False
