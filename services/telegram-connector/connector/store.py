"""The connector's own store.

Production keeps it in its own Postgres database (`comms_telegram`, slice
S2b-2); SQLite remains for tests, the load harness and the one-shot migration
(connector/migrate.py). The SQL below is written once, in the dialect both
accept (`?` placeholders are rewritten for Postgres), and runs on one
connection that only the store thread uses (connector/storethread.py), so
the event loop never waits on it.

Secret and content columns (the Telegram session, the callback secret, every
outbox and carryover body) are AES-GCM under
a key derived per connection from COMMS_STORE_KEY, so the file alone (or a
backup of it) gives nobody a Telegram login.

Update state (pts/qts/date and per-channel pts) is only ever written in the
same transaction as the outbox rows derived from it (proposal §5a): if the
process dies before that commit, Telegram replays the same updates.

Event sequence and restores: every number this store has ever issued is
below the next_seq it held when this process opened it (`seq_baseline`), and
nothing is delivered before the sequence has been checked with Rails once
per process (rails.learn_sequence). If Rails has committed a number at or
above that baseline, the volume is older than Rails (restored from a backup,
or a fresh store for a connection Rails already knows); its undelivered rows
are renumbered past Rails' sequence (`reconcile_sequence`) instead of being
acknowledged as already applied.
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
  -- Unused since sequences are checked with Rails at every start; kept so
  -- the schema does not change under an existing volume.
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
  ref TEXT NOT NULL, ord INTEGER PRIMARY KEY AUTOINCREMENT, body BLOB NOT NULL
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
  ref TEXT NOT NULL, seq INTEGER NOT NULL, body BLOB NOT NULL,
  delivered INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL,
  PRIMARY KEY (ref, seq)
);
CREATE INDEX IF NOT EXISTS outbox_pending ON outbox (ref, delivered, seq);
CREATE TABLE IF NOT EXISTS command_nonces (
  command_id TEXT PRIMARY KEY, seen_at REAL NOT NULL
);
"""

# The same tables in Postgres. Types widen where SQLite's INTEGER is 64-bit
# (channel ids, pts, Telegram ids); sealed columns are bytea. `ord` keeps the
# carryover's order as SQLite's AUTOINCREMENT did.
PG_SCHEMA = """
CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS connections (
  ref TEXT PRIMARY KEY,
  generation BIGINT NOT NULL DEFAULT 0,
  secret_version BIGINT NOT NULL DEFAULT 0,
  callback_secret BYTEA,
  session BYTEA,
  status TEXT NOT NULL DEFAULT 'new',
  identity TEXT,
  pts BIGINT, qts BIGINT, date BIGINT,
  self_id BIGINT,
  next_seq BIGINT NOT NULL DEFAULT 1,
  seq_known BIGINT NOT NULL DEFAULT 0,
  updated_at DOUBLE PRECISION
);
CREATE TABLE IF NOT EXISTS chats (
  ref TEXT NOT NULL, chat TEXT NOT NULL,
  synced BIGINT NOT NULL, kind TEXT,
  participants BIGINT,
  backfill_offset BIGINT, backfill_count BIGINT NOT NULL DEFAULT 0,
  backfill_done BIGINT NOT NULL DEFAULT 0, history_from TEXT,
  PRIMARY KEY (ref, chat)
);
CREATE TABLE IF NOT EXISTS carryover (
  ref TEXT NOT NULL, ord BIGSERIAL PRIMARY KEY, body BYTEA NOT NULL
);
CREATE TABLE IF NOT EXISTS channels (
  ref TEXT NOT NULL, channel_id BIGINT NOT NULL, pts BIGINT NOT NULL,
  PRIMARY KEY (ref, channel_id)
);
CREATE TABLE IF NOT EXISTS peer_messages (
  ref TEXT NOT NULL, message_id BIGINT NOT NULL, chat TEXT NOT NULL,
  PRIMARY KEY (ref, message_id)
);
CREATE TABLE IF NOT EXISTS outbox (
  ref TEXT NOT NULL, seq BIGINT NOT NULL, body BYTEA NOT NULL,
  delivered BIGINT NOT NULL DEFAULT 0, created_at DOUBLE PRECISION NOT NULL,
  PRIMARY KEY (ref, seq)
);
CREATE INDEX IF NOT EXISTS outbox_pending ON outbox (ref, delivered, seq);
CREATE TABLE IF NOT EXISTS command_nonces (
  command_id TEXT PRIMARY KEY, seen_at DOUBLE PRECISION NOT NULL
);
"""

SCHEMA_VERSION = 1

# Every table and its primary key, in the order the migration copies them.
TABLES = {
    "connections": ("ref",),
    "chats": ("ref", "chat"),
    "carryover": ("ord",),
    "channels": ("ref", "channel_id"),
    "peer_messages": ("ref", "message_id"),
    "outbox": ("ref", "seq"),
    "command_nonces": ("command_id",),
}


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


_PG_SQL = {}


def _pg(sql):
    """The shared SQL with Postgres placeholders (none of it holds a literal
    `?` or `%`)."""
    text = _PG_SQL.get(sql)
    if text is None:
        text = _PG_SQL[sql] = sql.replace("?", "%s")
    return text


class SqliteBackend:
    """Tests, the load harness and the migration's source/destination."""

    dialect = "sqlite"
    fatal = ()

    def __init__(self, path):
        self.conn = sqlite3.connect(path, isolation_level=None, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=FULL")
        self.conn.executescript(SCHEMA)

    def execute(self, sql, params=()):
        return self.conn.execute(sql, params)

    def begin(self):
        self.conn.execute("BEGIN IMMEDIATE")

    def commit(self):
        self.conn.execute("COMMIT")

    def rollback(self):
        self.conn.execute("ROLLBACK")

    def ping(self):
        self.conn.execute("SELECT 1").fetchone()

    def dump(self):
        """Everything stored, as text (tests check no secret is in it)."""
        return list(self.conn.iterdump())

    def close(self):
        self.conn.close()


# Held by the connector process for its whole life, on the store connection
# (see __main__ and storethread). It makes a second process wait; it never
# authorises taking over from one that might still be alive (that is slice
# 3's fencing). Fixed: "TGCONN01" as eight bytes.
ADVISORY_LOCK_KEY = int.from_bytes(b"TGCONN01", "big") - (1 << 63)


def connect_postgres(url):
    """One connection, in autocommit mode (transactions are explicit), with
    keepalives and timeouts so that a dead or silent server shows up as an
    error within seconds rather than as a call that never returns."""
    import psycopg
    from psycopg.rows import dict_row
    return psycopg.connect(
        url, autocommit=True, row_factory=dict_row, connect_timeout=10,
        keepalives=1, keepalives_idle=5, keepalives_interval=2, keepalives_count=3,
        tcp_user_timeout=10000, application_name="comms-telegram",
        options="-c statement_timeout=10000 -c lock_timeout=10000 -c idle_in_transaction_session_timeout=30000",
    )


class SchemaTooNew(Exception):
    pass


class PostgresBackend:
    dialect = "postgres"

    def __init__(self, conn):
        import psycopg
        self.fatal = (psycopg.OperationalError, psycopg.InterfaceError)
        self.conn = conn
        self.conn.execute(PG_SCHEMA)
        row = self.conn.execute("SELECT max(version) AS version FROM schema_version").fetchone()
        if row["version"] is None:
            self.conn.execute("INSERT INTO schema_version (version) VALUES (%s)", (SCHEMA_VERSION,))
        elif row["version"] > SCHEMA_VERSION:
            raise SchemaTooNew(row["version"])

    def execute(self, sql, params=()):
        return self.conn.execute(_pg(sql), params)

    def begin(self):
        self.conn.execute("BEGIN")

    def commit(self):
        self.conn.execute("COMMIT")

    def rollback(self):
        self.conn.execute("ROLLBACK")

    def ping(self):
        self.conn.execute("SELECT 1").fetchone()

    def dump(self):
        lines = []
        for table in TABLES:
            for row in self.conn.execute(f"SELECT * FROM {table}").fetchall():
                lines.append(f"{table} {row!r}")
        return lines

    def try_advisory_lock(self):
        return self.conn.execute("SELECT pg_try_advisory_lock(%s) AS ok", (ADVISORY_LOCK_KEY,)).fetchone()["ok"]

    def close(self):
        self.conn.close()


class Store:
    """Synchronous. In the running connector only the store thread calls it
    (connector/storethread.py); tests may call it directly."""

    def __init__(self, backend, crypto):
        self.crypto = crypto
        # Tests and the fake-provider e2e set this to inject a crash at a
        # named point (see faults()). Never set in production.
        self.fault = None
        self.db = SqliteBackend(backend) if isinstance(backend, (str, os.PathLike)) else backend
        # next_seq of each connection as this process found it, before it
        # issued anything (see the module docstring), and the connections
        # whose sequence has been checked with Rails in this process.
        self._seq_baseline = {row["ref"]: row["next_seq"] for row in self.connections()}
        self._seq_checked = set()

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
        self.db.execute("INSERT INTO connections (ref, updated_at) VALUES (?, ?) ON CONFLICT (ref) DO NOTHING", (ref, time.time()))
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
        self._seq_baseline.pop(ref, None)
        self._seq_checked.discard(ref)

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
        reset = ("UPDATE chats SET backfill_offset = NULL, backfill_count = 0, backfill_done = 0, "
                 "history_from = NULL WHERE ref = ? AND synced = 1")
        if chats is None:
            self.db.execute(reset, (ref,))
        else:
            for chat in chats:
                self.db.execute(reset + " AND chat = ?", (ref, chat))

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
        self.db.execute("INSERT INTO peer_messages (ref, message_id, chat) VALUES (?, ?, ?) "
                        "ON CONFLICT (ref, message_id) DO UPDATE SET chat = excluded.chat",
                        (ref, message_id, chat))

    def delete_channel(self, ref, channel_id):
        self.db.execute("DELETE FROM channels WHERE ref = ? AND channel_id = ?", (ref, channel_id))

    def peer_of(self, ref, message_id):
        row = self.db.execute("SELECT chat FROM peer_messages WHERE ref = ? AND message_id = ?",
                              (ref, message_id)).fetchone()
        return row and row["chat"]

    # -- outbox -------------------------------------------------------------

    def enqueue(self, ref, event):
        """Appends one event with the connection's next sequence number."""
        self.seq_baseline(ref)
        row = self.connection(ref)
        seq = row["next_seq"]
        event = dict(event, seq=seq)
        self.db.execute("INSERT INTO outbox (ref, seq, body, created_at) VALUES (?, ?, ?, ?)",
                        (ref, seq, self._seal(ref, event), time.time()))
        self.db.execute("UPDATE connections SET next_seq = ? WHERE ref = ?", (seq + 1, ref))
        return seq

    def replace_pending(self, ref, seq, event):
        """Rewrites one undelivered row in place, keeping its sequence number
        (Rails needs the sequence without holes)."""
        self.db.execute("UPDATE outbox SET body = ? WHERE ref = ? AND seq = ? AND delivered = 0",
                        (self._seal(ref, dict(event, seq=seq)), ref, seq))

    def set_aside_pending(self, ref, keep):
        """A new login attempt: Rails will refuse the old session's chats and
        messages until the new one is connected, and would block the attempt's
        own events behind them. Every undelivered row becomes a no-op in place
        (so the sequence keeps no holes); those `keep(event)` selects are
        copied to the carryover, to be queued again after `connected`."""
        with self.transaction():
            for row in self.db.execute("SELECT seq, body FROM outbox WHERE ref = ? AND delivered = 0 ORDER BY seq",
                                       (ref,)).fetchall():
                event = self._open(ref, row["body"])
                if keep(event):
                    event.pop("seq", None)
                    self.db.execute("INSERT INTO carryover (ref, body) VALUES (?, ?)", (ref, self._seal(ref, event)))
                self.replace_pending(ref, row["seq"], NOOP_EVENT)

    def take_carryover(self, ref):
        """Moves the carryover back into the outbox (call inside a transaction)."""
        rows = self.db.execute("SELECT ord, body FROM carryover WHERE ref = ? ORDER BY ord", (ref,)).fetchall()
        for row in rows:
            self.enqueue(ref, self._open(ref, row["body"]))
        self.db.execute("DELETE FROM carryover WHERE ref = ?", (ref,))
        return len(rows)

    # -- sequence check with Rails (once per process) ----------------------------

    def seq_baseline(self, ref):
        """next_seq when this process first saw the connection: every number
        this store issued before is below it."""
        if ref not in self._seq_baseline:
            row = self.connection(ref)
            if row is None:
                return None
            self._seq_baseline[ref] = row["next_seq"]
        return self._seq_baseline[ref]

    def sequence_checked(self, ref):
        return ref in self._seq_checked

    def forget_sequence_check(self, ref):
        self._seq_checked.discard(ref)

    def reconcile_sequence(self, ref, committed):
        """Rails says it has committed up to `committed`. Below the baseline
        that is ordinary (rows it committed are acknowledged on delivery).
        At or above it, Rails holds numbers this store never issued since it
        was last written: the volume is behind Rails. Every undelivered row
        is renumbered from committed + 1, in order, so it is applied rather
        than acknowledged unseen. Returns True when it renumbered."""
        baseline = self.seq_baseline(ref)
        if baseline is None:
            return False
        renumbered = committed >= baseline
        if renumbered:
            self.renumber(ref, committed)
        self._seq_checked.add(ref)
        return renumbered

    def renumber(self, ref, committed):
        """Every undelivered row moves past `committed`, keeping its order
        and leaving no holes; delivered rows (kept for diagnosis) go, since
        their numbers no longer mean anything to Rails."""
        with self.transaction():
            self.db.execute("DELETE FROM outbox WHERE ref = ? AND delivered = 1", (ref,))
            rows = self.db.execute("SELECT seq, body FROM outbox WHERE ref = ? ORDER BY seq", (ref,)).fetchall()
            # Out of the way first (negative numbers), so no new number can
            # collide with an old one.
            self.db.execute("UPDATE outbox SET seq = -seq WHERE ref = ?", (ref,))
            seq = committed
            for row in rows:
                seq += 1
                event = self._open(ref, row["body"])
                event["seq"] = seq
                self.db.execute("UPDATE outbox SET seq = ?, body = ? WHERE ref = ? AND seq = ?",
                                (seq, self._seal(ref, event), ref, -row["seq"]))
            self.db.execute("UPDATE connections SET next_seq = ? WHERE ref = ?", (seq + 1, ref))
            self._seq_baseline[ref] = seq + 1

    def pending(self, ref, limit=50):
        """Undelivered rows, oldest first, as {"seq", "body"} with the body
        opened (the JSON text that is posted)."""
        rows = self.db.execute(
            "SELECT seq, body FROM outbox WHERE ref = ? AND delivered = 0 ORDER BY seq LIMIT ?", (ref, limit)
        ).fetchall()
        return [{"seq": row["seq"], "body": self.crypto.open(ref, row["body"])} for row in rows]

    def _seal(self, ref, event):
        # Outbox and carryover rows hold message text, names and captions:
        # sealed like the session, so the volume holds no content in clear.
        return self.crypto.seal(ref, encode(event))

    def _open(self, ref, sealed):
        return json.loads(self.crypto.open(ref, sealed))

    def pending_count(self, ref):
        return self.db.execute("SELECT COUNT(*) AS n FROM outbox WHERE ref = ? AND delivered = 0",
                               (ref,)).fetchone()["n"]

    def oldest_pending_age(self, ref):
        row = self.db.execute("SELECT MIN(created_at) AS oldest FROM outbox WHERE ref = ? AND delivered = 0",
                              (ref,)).fetchone()
        return row["oldest"] and time.time() - row["oldest"]

    def mark_delivered(self, ref, through_seq):
        self.db.execute("UPDATE outbox SET delivered = 1 WHERE ref = ? AND seq <= ? AND delivered = 0",
                        (ref, through_seq))
        # Delivered rows are kept a day for diagnosis, then dropped.
        self.db.execute("DELETE FROM outbox WHERE ref = ? AND delivered = 1 AND created_at < ?",
                        (ref, time.time() - 86400))

    # -- command replay protection ------------------------------------------

    def consume_command_id(self, command_id, now, retention):
        self.db.execute("DELETE FROM command_nonces WHERE seen_at < ?", (now - retention,))
        cursor = self.db.execute("INSERT INTO command_nonces (command_id, seen_at) VALUES (?, ?) "
                                 "ON CONFLICT (command_id) DO NOTHING", (command_id, now))
        return cursor.rowcount == 1

    def ping(self):
        self.db.ping()


class _Transaction:
    def __init__(self, db):
        self.db = db

    def __enter__(self):
        self.db.begin()
        return self

    def __exit__(self, exc_type, exc, tb):
        if exc_type:
            self.db.rollback()
        else:
            self.db.commit()
        return False
