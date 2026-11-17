"""python -m connector.backup: the store's own encrypted backup.

  dump      a consistent snapshot of the connector's database, sealed, to stdout
  restore   a sealed dump into an empty database, verified, then committed

`dump` runs beside the live connector: its own read-only connection, one
REPEATABLE READ READ ONLY transaction (one snapshot), no ownership lock, no
store thread. The house's nightly backup runs it with `docker exec` and only
ever carries ciphertext (README "Backup").

`restore` runs with the connector stopped, like connector.migrate: it holds
the volume's locks and the database's advisory lock throughout, refuses a
database with any row in any connector table, imports in one transaction, and
commits only after the last chunk's tag, the trailer and a read-back of every
table have all checked out. Anything else rolls back and leaves the database
empty. Before importing it makes `.lease` a directory, as the migration
does, so the image from before the move cannot start there; a refusal at that
step leaves the database empty, and nothing fallible follows the commit.

Nothing is decrypted on the way: sealed columns travel as the bytes they are.
What the dump adds is a second seal over the whole stream, under a key that
exists for this dump only:

  key = HKDF-SHA256(COMMS_STORE_KEY, salt = 32 random bytes per dump,
                    info = "souls-house-telegram-backup-v1")

So the backup is exactly as recoverable as COMMS_STORE_KEY. Lose the key and
the backup is noise; that is the point, and it is written down.

Format, version 1 (all integers big-endian):

  magic        8 bytes   b"TGBACKUP"
  format       1 byte    1
  header_len   4 bytes   at most 65536
  header       header_len bytes of UTF-8 JSON, sorted keys
  chunks       one or more of:
                 length  4 bytes   ciphertext length, 16..CHUNK_SIZE+16
                 data    AES-256-GCM(key, nonce, plaintext, aad) with tag

  nonce = chunk index (8 bytes) + final flag (1 byte: 1 on the last chunk,
          else 0) + 3 zero bytes. Unique per key, and the key is per dump.
  aad   = SHA-256(magic + format + header_len + header) + the nonce

The header (salt, schema version, chunk size, the snapshot's per-table row
counts, per-connection next_seq and highest outbox seq, the carryover
sequence) is authenticated through every chunk's aad but is not secret. The
plaintext is JSON lines: {"t": table, "r": row} with bytes as {"b64": ...},
then one {"end": ...} trailer with per-table counts and SHA-256 digests of
the rows in primary-key order. Restore rejects: a wrong magic or format, a
newer schema, a bad tag (wrong key, tampering), a missing final chunk
(truncation), bytes after it, a record after the trailer, an unknown table or
column, a header that disagrees with the rows, and a read-back that disagrees
with the trailer.

Memory stays bounded: rows are read through a server-side cursor and written
chunk by chunk; restore holds one chunk and one record at a time.
"""

import argparse
import base64
import hashlib
import json
import os
import struct
import sys
import time

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from .store import SCHEMA_VERSION, TABLES, PostgresBackend

MAGIC = b"TGBACKUP"
FORMAT = 1
MAX_HEADER = 65536
CHUNK_SIZE = 1 << 20
MAX_RECORD = 16 << 20
INFO = b"souls-house-telegram-backup-v1"
TEXT_KEYS = {"ref", "chat", "command_id"}  # ordered byte-wise (COLLATE "C") on both sides


class Invalid(Exception):
    """A dump that must not be restored. The message names the check, never a value."""


def _key(master, salt):
    if not master or len(master) < 32:
        raise ValueError("COMMS_STORE_KEY must be at least 32 characters")
    master = master.encode() if isinstance(master, str) else master
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=INFO).derive(master)


def _nonce(index, final):
    return struct.pack(">QB", index, 1 if final else 0) + b"\0\0\0"


def _order(table):
    return ", ".join(f'{c} COLLATE "C"' if c in TABLES[table] and c in TEXT_KEYS else c
                     for c in TABLES[table])


def _encode_value(value):
    if isinstance(value, memoryview):
        value = bytes(value)
    if isinstance(value, bytes):
        return {"b64": base64.b64encode(value).decode()}
    return value


def _decode_value(value):
    if isinstance(value, dict):
        if set(value) != {"b64"}:
            raise Invalid("value")
        return base64.b64decode(value["b64"], validate=True)
    return value


def _row_digest(digest, row):
    digest.update(json.dumps({k: _encode_value(v) for k, v in row.items()},
                             sort_keys=True, separators=(",", ":")).encode())
    digest.update(b"\n")


def _carryover_sequence(execute):
    row = execute("SELECT pg_get_serial_sequence('carryover', 'ord') AS name").fetchone()
    state = execute(f"SELECT last_value, is_called FROM {row['name']}").fetchone()
    return row["name"], {"last_value": state["last_value"], "is_called": bool(state["is_called"])}


def _columns(conn):
    rows = conn.execute(
        "SELECT table_name, column_name FROM information_schema.columns "
        "WHERE table_schema = current_schema() ORDER BY table_name, ordinal_position").fetchall()
    columns = {}
    for row in rows:
        if row["table_name"] in TABLES:
            columns.setdefault(row["table_name"], []).append(row["column_name"])
    return columns


def _snapshot_facts(conn):
    counts = {t: conn.execute(f"SELECT count(*) AS n FROM {t}").fetchone()["n"] for t in TABLES}
    sequences = {}
    for row in conn.execute("SELECT ref, next_seq FROM connections ORDER BY ref COLLATE \"C\"").fetchall():
        sequences[row["ref"]] = {"next_seq": row["next_seq"], "max_seq": None}
    for row in conn.execute("SELECT ref, max(seq) AS max_seq FROM outbox GROUP BY ref").fetchall():
        sequences.setdefault(row["ref"], {"next_seq": None, "max_seq": None})["max_seq"] = row["max_seq"]
    return counts, sequences


def connect(url):
    """Its own connection, with timeouts long enough for a whole dump."""
    import psycopg
    from psycopg.rows import dict_row
    return psycopg.connect(
        url, autocommit=True, row_factory=dict_row, connect_timeout=10,
        keepalives=1, keepalives_idle=5, keepalives_interval=2, keepalives_count=3,
        application_name="comms-telegram-backup",
        options="-c statement_timeout=300000 -c lock_timeout=10000 -c idle_in_transaction_session_timeout=300000",
    )


# -- writing ---------------------------------------------------------------------------

class _Sealer:
    def __init__(self, out, aead, header_hash, chunk_size):
        self.out, self.aead, self.header_hash, self.chunk_size = out, aead, header_hash, chunk_size
        self.buffer = bytearray()
        self.index = 0

    def write(self, data):
        self.buffer += data
        while len(self.buffer) > self.chunk_size:  # keep at least one byte for the final chunk
            self._emit(bytes(self.buffer[:self.chunk_size]), False)
            del self.buffer[:self.chunk_size]

    def finish(self):
        self._emit(bytes(self.buffer), True)
        self.buffer = bytearray()

    def _emit(self, plaintext, final):
        nonce = _nonce(self.index, final)
        sealed = self.aead.encrypt(nonce, plaintext, self.header_hash + nonce)
        self.out.write(struct.pack(">I", len(sealed)) + sealed)
        self.index += 1


def dump(database_url, master_key, out, chunk_size=CHUNK_SIZE, now=time.time):
    """Writes one sealed dump to `out` (binary). Returns a summary without values."""
    conn = connect(database_url)
    try:
        conn.autocommit = False
        import psycopg
        conn.isolation_level = psycopg.IsolationLevel.REPEATABLE_READ
        conn.read_only = True
        with conn.transaction():
            row = conn.execute("SELECT max(version) AS version FROM schema_version").fetchone()
            if row["version"] != SCHEMA_VERSION:
                raise Invalid("schema_version")
            columns = _columns(conn)
            if set(columns) != set(TABLES):
                raise Invalid("tables")
            counts, sequences = _snapshot_facts(conn)
            _, carryover_seq = _carryover_sequence(conn.execute)
            salt = os.urandom(32)
            header = {
                "format": FORMAT, "schema_version": SCHEMA_VERSION, "salt": salt.hex(),
                "chunk_size": chunk_size, "created_at": now(), "tables": list(TABLES),
                "columns": columns, "counts": counts, "sequences": sequences,
                "carryover_sequence": carryover_seq,
            }
            header_bytes = json.dumps(header, sort_keys=True, separators=(",", ":")).encode()
            if len(header_bytes) > MAX_HEADER:
                raise Invalid("header_too_large")
            prefix = MAGIC + bytes([FORMAT]) + struct.pack(">I", len(header_bytes)) + header_bytes
            out.write(prefix)
            sealer = _Sealer(out, AESGCM(_key(master_key, salt)), hashlib.sha256(prefix).digest(), chunk_size)
            digests, written = {}, {}
            for table in TABLES:
                digest, n = hashlib.sha256(), 0
                with conn.cursor(name=f"backup_{table}") as cursor:
                    cursor.itersize = 500
                    cursor.execute(f"SELECT {', '.join(columns[table])} FROM {table} ORDER BY {_order(table)}")
                    for record in cursor:
                        row = dict(record)
                        _row_digest(digest, row)
                        line = json.dumps({"t": table, "r": {k: _encode_value(v) for k, v in row.items()}},
                                          separators=(",", ":")).encode() + b"\n"
                        if len(line) > MAX_RECORD:
                            raise Invalid("record_too_large")
                        sealer.write(line)
                        n += 1
                if n != counts[table]:
                    raise Invalid(f"snapshot_changed:{table}")
                digests[table], written[table] = digest.hexdigest(), n
            sealer.write(json.dumps({"end": {"counts": written, "digests": digests}},
                                    separators=(",", ":")).encode() + b"\n")
            sealer.finish()
            out.flush()
        return {"tables": written, "connections": len(sequences), "chunks": sealer.index}
    finally:
        conn.close()


# -- reading ---------------------------------------------------------------------------

def _read_exact(source, n, what):
    data = bytearray()
    while len(data) < n:
        part = source.read(n - len(data))
        if not part:
            raise Invalid(f"truncated:{what}")
        data += part
    return bytes(data)


def read_header(source):
    magic = source.read(len(MAGIC))
    if magic != MAGIC:
        raise Invalid("magic")
    version = _read_exact(source, 1, "format")
    if version[0] != FORMAT:
        raise Invalid("format")
    (length,) = struct.unpack(">I", _read_exact(source, 4, "header_len"))
    if length > MAX_HEADER:
        raise Invalid("header_len")
    header_bytes = _read_exact(source, length, "header")
    try:
        header = json.loads(header_bytes)
    except ValueError:
        raise Invalid("header")
    if not isinstance(header, dict) or header.get("format") != FORMAT:
        raise Invalid("header")
    if header.get("schema_version") != SCHEMA_VERSION:
        raise Invalid("schema_version")
    if header.get("tables") != list(TABLES) or set(header.get("columns", {})) != set(TABLES):
        raise Invalid("tables")
    chunk_size = header.get("chunk_size")
    if not isinstance(chunk_size, int) or not 1 <= chunk_size <= 16 << 20:
        raise Invalid("chunk_size")
    prefix = MAGIC + version + struct.pack(">I", length) + header_bytes
    return header, hashlib.sha256(prefix).digest()


def records(source, master_key):
    """Yields (header, None) first, then each decoded record, in order. Every
    chunk is authenticated before any of its records is yielded."""
    header, header_hash = read_header(source)
    yield header, None
    aead = AESGCM(_key(master_key, bytes.fromhex(header["salt"])))
    limit = header["chunk_size"] + 16
    index, pending, final = 0, b"", False
    while not final:
        raw = source.read(4)
        if len(raw) == 0:
            raise Invalid("truncated:no_final_chunk")
        if len(raw) < 4:
            raise Invalid("truncated:chunk_len")
        (length,) = struct.unpack(">I", raw)
        if not 16 <= length <= limit:
            raise Invalid("chunk_len")
        sealed = _read_exact(source, length, "chunk")
        plaintext = None
        for flag in (False, True):
            nonce = _nonce(index, flag)
            try:
                plaintext = aead.decrypt(nonce, sealed, header_hash + nonce)
                final = flag
                break
            except Exception:
                continue
        if plaintext is None:
            raise Invalid("tag")  # wrong key, tampering, reordering
        index += 1
        pending += plaintext
        *lines, pending = pending.split(b"\n")
        if len(pending) > MAX_RECORD:
            raise Invalid("record_too_large")
        for line in lines:
            try:
                yield None, json.loads(line)
            except ValueError:
                raise Invalid("record")
    if pending:
        raise Invalid("record")
    if source.read(1):
        raise Invalid("trailing_data")


def _validated_rows(source, master_key, header_sink):
    """Yields (table, row) and finally ("end", trailer), checking order,
    tables, columns, counts and digests against the header and trailer."""
    stream = records(source, master_key)
    header, _ = next(stream)
    header_sink(header)
    columns = header["columns"]
    order = list(TABLES)
    position, digests, counts, trailer = 0, {}, {}, None
    for _, record in stream:
        if trailer is not None:
            raise Invalid("record_after_trailer")
        if not isinstance(record, dict):
            raise Invalid("record")
        if "end" in record:
            trailer = record["end"]
            continue
        table, row = record.get("t"), record.get("r")
        if table not in TABLES or not isinstance(row, dict):
            raise Invalid("record")
        if order.index(table) < position:
            raise Invalid("table_order")
        position = order.index(table)
        if list(row) != columns[table]:
            raise Invalid(f"columns:{table}")
        decoded = {k: _decode_value(v) for k, v in row.items()}
        _row_digest(digests.setdefault(table, hashlib.sha256()), decoded)
        counts[table] = counts.get(table, 0) + 1
        yield table, decoded
    if not isinstance(trailer, dict):
        raise Invalid("no_trailer")
    for table in TABLES:
        n = counts.get(table, 0)
        if n != header["counts"].get(table) or n != trailer["counts"].get(table):
            raise Invalid(f"count:{table}")
        if (digests.get(table) or hashlib.sha256()).hexdigest() != trailer["digests"].get(table):
            raise Invalid(f"digest:{table}")
    yield "end", trailer


def verify(source, master_key):
    """Reads a whole dump without a database: every check restore makes on the stream."""
    seen = {}
    for table, _ in _validated_rows(source, master_key, lambda h: seen.setdefault("header", h)):
        if table == "end":
            break
    header = seen["header"]
    return {"tables": header["counts"], "connections": len(header["sequences"]), "created_at": header["created_at"]}


# -- restoring -------------------------------------------------------------------------

def restore(data_dir, database_url, master_key, source):
    from . import migrate  # its locks, cutover and refusals
    if os.path.exists(os.path.join(data_dir, migrate.SQLITE_NAME)):
        raise migrate.Refused("unmigrated_sqlite_store")
    owner = migrate.Ownership(data_dir, database_url)
    try:
        backend = PostgresBackend(owner.conn)  # creates the schema if absent
        nonempty = [t for t in TABLES if backend.execute(f"SELECT 1 FROM {t} LIMIT 1").fetchone()]
        if nonempty:
            raise migrate.Refused("database_not_empty:" + ",".join(nonempty))
        # The old-image interlock comes before any import: its refusal (no
        # atomic exchange) leaves the destination empty, and nothing that can
        # fail runs after the commit. A directory .lease left by a restore that
        # then fails is harmless; the volume is for this image either way.
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        migrate.retire_old_lease(data_dir, stamp)
        migrate._fsync_dir(data_dir)
        seen = {}
        backend.begin()
        try:
            for table, row in _validated_rows(source, master_key, lambda h: seen.setdefault("header", h)):
                if table == "end":
                    trailer = row
                    break
                cols = list(row)
                owner.conn.execute(
                    f"INSERT INTO {table} ({', '.join(cols)}) VALUES ({', '.join(['%s'] * len(cols))})",
                    [row[c] for c in cols])
            header = seen["header"]
            name, _ = _carryover_sequence(owner.conn.execute)
            state = header["carryover_sequence"]
            highest = owner.conn.execute("SELECT max(ord) AS m FROM carryover").fetchone()["m"]
            if highest is not None and (state["last_value"] < highest or not state["is_called"]):
                raise Invalid("carryover_sequence")
            owner.conn.execute("SELECT setval(%s, %s, %s)", (name, state["last_value"], state["is_called"]))
            _check_readback(owner.conn, header, trailer)
            backend.commit()
        except BaseException:
            backend.rollback()
            raise
        return {"tables": trailer["counts"], "connections": len(header["sequences"]),
                "created_at": header["created_at"]}
    finally:
        owner.close()


def _check_readback(conn, header, trailer):
    for table in TABLES:
        digest, n = hashlib.sha256(), 0
        cols = header["columns"][table]
        # A server-side cursor, as in dump: the read-back streams, it does not
        # buffer a whole table (the restore transaction is open, as DECLARE needs).
        with conn.cursor(name=f"readback_{table}") as cursor:
            cursor.itersize = 500
            cursor.execute(f"SELECT {', '.join(cols)} FROM {table} ORDER BY {_order(table)}")
            for record in cursor:
                row = {k: (bytes(v) if isinstance(v, memoryview) else v) for k, v in dict(record).items()}
                _row_digest(digest, row)
                n += 1
        if n != trailer["counts"][table] or digest.hexdigest() != trailer["digests"][table]:
            raise Invalid(f"readback:{table}")
    for ref, expected in header["sequences"].items():
        row = conn.execute("SELECT next_seq FROM connections WHERE ref = %s", (ref,)).fetchone()
        top = conn.execute("SELECT max(seq) AS m FROM outbox WHERE ref = %s", (ref,)).fetchone()["m"]
        if (row["next_seq"] if row else None) != expected["next_seq"] or top != expected["max_seq"]:
            raise Invalid("sequences")


# -- command line ----------------------------------------------------------------------

def _arm_deadline(seconds):
    """The dump's own lifetime bound. Rails kills only its `docker exec`
    client, which need not end the process Docker started in the container;
    this ends it from inside. The connection goes with the process, and with it
    the snapshot. One write to fd 2 (no logging locks), then os._exit."""
    import threading

    def expire():
        try:
            os.write(2, b'{"failed": "deadline"}\n')
        finally:
            os._exit(124)

    timer = threading.Timer(seconds, expire)
    timer.daemon = True
    timer.start()
    return timer


def main(argv=None, env=os.environ, stdin=None, stdout=None, stderr=None):
    stdin = stdin or sys.stdin.buffer
    stdout = stdout or sys.stdout.buffer
    stderr = stderr or sys.stderr
    parser = argparse.ArgumentParser(prog="python -m connector.backup", description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=["dump", "restore", "verify"])
    parser.add_argument("--data-dir", default=env.get("COMMS_DATA_DIR", "/data"))
    parser.add_argument("--in", dest="path", help="restore/verify: read this file instead of stdin")
    parser.add_argument("--deadline", type=float, default=float(env.get("COMMS_BACKUP_DEADLINE", "600")),
                        help="dump: exit 124 after this many seconds, whatever is happening")
    args = parser.parse_args(argv)
    key = env.get("COMMS_STORE_KEY", "")
    url = env.get("COMMS_DATABASE_URL", "")

    def report(payload, code):
        # Diagnostics go to stderr: stdout carries only the sealed dump.
        print(json.dumps(payload, sort_keys=True), file=stderr)
        return code

    if len(key) < 32:
        return report({"refused": "store_key"}, 2)
    if args.command != "verify" and not url.startswith(("postgresql://", "postgres://")):
        return report({"refused": "database_url"}, 2)
    from . import migrate
    try:
        if args.command == "dump":
            timer = _arm_deadline(args.deadline)
            try:
                return report(dict(dump(url, key, stdout), done="dump"), 0)
            finally:
                timer.cancel()
        source = open(args.path, "rb") if args.path else stdin
        try:
            if args.command == "verify":
                return report(dict(verify(source, key), done="verify"), 0)
            return report(dict(restore(args.data_dir, url, key, source), done="restore"), 0)
        finally:
            if args.path:
                source.close()
    except (Invalid, migrate.Refused) as refused:
        return report({"refused": str(refused)}, 2)
    except Exception as error:  # never a DSN or a value: the class only
        return report({"failed": type(error).__name__}, 1)


if __name__ == "__main__":
    sys.exit(main())
