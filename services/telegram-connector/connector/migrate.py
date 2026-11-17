"""python -m connector.migrate: move the store between SQLite and Postgres.

  sqlite-to-postgres   the one-shot move to the connector's own database
  postgres-to-sqlite   the explicit rollback (never a plain restart)
  empty-postgres       after a rollback, before migrating again

Run with the connector stopped (`bin/kamal accessory stop comms-telegram`),
in the connector's image, with the volume mounted and COMMS_DATABASE_URL set:

  docker run --rm -v comms_telegram:/data -e COMMS_DATABASE_URL=... \\
      <image> python -m connector.migrate sqlite-to-postgres

Ownership, throughout: the volume's locks (the old image's `.lease` and this
image's `.owner`, both exclusive, non-blocking) and the database's advisory
lock. If any is held, something is still running and the command refuses.

Nothing is decrypted: sealed columns are copied as bytes. Every row of every
table is compared, column by column and byte for byte, before the copy is
committed and again after. The destination must be empty (or, for a rerun
after an interrupted cutover, already equal to the source). The source is
kept: renamed, never deleted.

Cutover, after a verified copy (sqlite-to-postgres):
  1. `.lease` becomes a directory. The pre-migration image opens it to lock
     it, fails, and refuses to start (reason=lease) instead of creating an
     empty store. This image does not start on a volume whose `.lease` is
     still a file (reason=pre_migration_lock_file).
  2. `telegram.sqlite3` is renamed `telegram.sqlite3.migrated-<time>`. This
     image does not start while a `telegram.sqlite3` is present
     (reason=unmigrated_sqlite_store).
In that order: interrupted between the two, neither image starts, and a
rerun finishes the cutover.

The rollback reverses it: a verified SQLite copy of the database, `.lease`
a file again. The database keeps its copy; this image will not start on the
volume until it is migrated again, which needs `empty-postgres` first (the
old image will have written to the SQLite store since).

Prints one JSON summary: counts per table, and per connection its outbox
rows, highest sequence and next_seq. No refs' secrets, no content.
"""

import argparse
import fcntl
import json
import os
import sqlite3
import sys
import time

from .store import ADVISORY_LOCK_KEY, TABLES, PostgresBackend, SqliteBackend, connect_postgres

SQLITE_NAME = "telegram.sqlite3"
OLD_LOCK = ".lease"
OWNER_LOCK = ".owner"
LEASE_NOTE = """This volume's store moved to Postgres (connector.migrate sqlite-to-postgres).
.lease is a directory so that the connector image from before the move
refuses to start here instead of opening an empty store. To go back, run
connector.migrate postgres-to-sqlite, never a plain restart of the old image.
"""


class Refused(Exception):
    pass


# -- locks ----------------------------------------------------------------------

def _flock(path, reason):
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        raise Refused(reason)
    return fd


class Ownership:
    """The volume's locks and the database's advisory lock, held until close."""

    def __init__(self, data_dir, database_url):
        self.fds = []
        old = os.path.join(data_dir, OLD_LOCK)
        if not os.path.isdir(old):  # a directory: the old image cannot run at all
            self.fds.append(_flock(old, "old_connector_running"))
        self.fds.append(_flock(os.path.join(data_dir, OWNER_LOCK), "connector_running"))
        self.conn = connect_postgres(database_url)
        if not self.conn.execute("SELECT pg_try_advisory_lock(%s) AS ok", (ADVISORY_LOCK_KEY,)).fetchone()["ok"]:
            self.close()
            raise Refused("database_locked")

    def close(self):
        for fd in self.fds:
            os.close(fd)
        self.fds = []
        if self.conn is not None:
            self.conn.close()
            self.conn = None


# -- reading and comparing ------------------------------------------------------------

def _value(value):
    if isinstance(value, memoryview):
        return bytes(value)
    return value


def read_table(execute, table):
    """Every row, ordered by primary key, as {column: value} with bytes."""
    order = ", ".join(TABLES[table])
    rows = execute(f"SELECT * FROM {table} ORDER BY {order}").fetchall()
    return [{key: _value(row[key]) for key in row.keys()} for row in rows]


def read_all(execute):
    return {table: read_table(execute, table) for table in TABLES}


def compare(source, destination):
    """Raises Refused naming the first table that differs (no values)."""
    for table in TABLES:
        a, b = source[table], destination[table]
        if len(a) != len(b):
            raise Refused(f"verify_failed:{table}:rows {len(a)} != {len(b)}")
        for index, (x, y) in enumerate(zip(a, b)):
            if set(x) != set(y):
                raise Refused(f"verify_failed:{table}:columns")
            for column in x:
                if x[column] != y[column] or type(x[column]) is bytes and not isinstance(y[column], bytes):
                    raise Refused(f"verify_failed:{table}:row {index} column {column}")


def summary(snapshot):
    per_ref = {}
    for row in snapshot["connections"]:
        per_ref[row["ref"]] = {"next_seq": row["next_seq"], "outbox": 0, "max_seq": None,
                               "undelivered": 0, "carryover": 0}
    for row in snapshot["outbox"]:
        entry = per_ref.setdefault(row["ref"], {"next_seq": None, "outbox": 0, "max_seq": None,
                                                "undelivered": 0, "carryover": 0})
        entry["outbox"] += 1
        entry["undelivered"] += 0 if row["delivered"] else 1
        entry["max_seq"] = max(entry["max_seq"] or 0, row["seq"])
    for row in snapshot["carryover"]:
        per_ref.setdefault(row["ref"], {"next_seq": None, "outbox": 0, "max_seq": None,
                                        "undelivered": 0, "carryover": 0})["carryover"] += 1
    # refs are opaque service ids (svc_N), not secrets; Rails holds the same.
    return {"tables": {table: len(rows) for table, rows in snapshot.items()}, "connections": per_ref}


def _insert(execute, table, rows, placeholder):
    if not rows:
        return
    columns = list(rows[0])
    sql = (f"INSERT INTO {table} ({', '.join(columns)}) "
           f"VALUES ({', '.join([placeholder] * len(columns))})")
    for row in rows:
        execute(sql, [row[c] for c in columns])


def _empty(snapshot):
    return all(not rows for rows in snapshot.values())


def _sqlite_reader(path):
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    # Fold the WAL into the main file, so the file renamed later is whole.
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    return conn


# -- the commands -------------------------------------------------------------------

def sqlite_to_postgres(data_dir, database_url):
    source_path = os.path.join(data_dir, SQLITE_NAME)
    if not os.path.isfile(source_path):
        raise Refused("no_sqlite_store")
    owner = Ownership(data_dir, database_url)
    try:
        source_conn = _sqlite_reader(source_path)
        source = read_all(source_conn.execute)
        backend = PostgresBackend(owner.conn)  # creates the schema if absent
        existing = read_all(backend.execute)
        if not _empty(existing):
            # A rerun after an interrupted cutover finds its own copy.
            compare(source, existing)
            copied = False
        else:
            backend.begin()
            try:
                for table in TABLES:
                    _insert(owner.conn.execute, table, source[table], "%s")
                if source["carryover"]:
                    owner.conn.execute("SELECT setval(pg_get_serial_sequence('carryover', 'ord'), %s)",
                                       (max(row["ord"] for row in source["carryover"]),))
                compare(source, read_all(backend.execute))
                backend.commit()
            except BaseException:
                backend.rollback()
                raise
            copied = True
        compare(source, read_all(backend.execute))  # what was committed
        source_conn.close()
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        # 1. The old image can no longer start here.
        lease = os.path.join(data_dir, OLD_LOCK)
        if not os.path.isdir(lease):
            os.rename(lease, f"{lease}.migrated-{stamp}")
            os.mkdir(lease, 0o700)
            with open(os.path.join(lease, "README"), "w") as handle:
                handle.write(LEASE_NOTE)
        # 2. The source is kept, under another name.
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(source_path + suffix):
                os.rename(source_path + suffix, f"{source_path}.migrated-{stamp}{suffix}")
        _fsync_dir(data_dir)
        return dict(summary(source), copied=copied, source_kept=f"{SQLITE_NAME}.migrated-{stamp}")
    finally:
        owner.close()


def postgres_to_sqlite(data_dir, database_url):
    destination_path = os.path.join(data_dir, SQLITE_NAME)
    if os.path.exists(destination_path):
        raise Refused("destination_exists")
    owner = Ownership(data_dir, database_url)
    temporary = destination_path + ".rollback-tmp"
    try:
        backend = PostgresBackend(owner.conn)
        source = read_all(backend.execute)
        if _empty(source):
            raise Refused("database_empty")
        if os.path.exists(temporary):
            os.remove(temporary)
        target = SqliteBackend(temporary)
        target.begin()
        for table in TABLES:
            _insert(target.execute, table, source[table], "?")
        target.commit()
        compare(source, read_all(target.execute))
        target.conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        target.close()
        with open(temporary, "rb") as handle:
            os.fsync(handle.fileno())
        os.rename(temporary, destination_path)
        for suffix in ("-wal", "-shm"):
            if os.path.exists(temporary + suffix):
                os.remove(temporary + suffix)
        lease = os.path.join(data_dir, OLD_LOCK)
        if os.path.isdir(lease):
            note = os.path.join(lease, "README")
            if os.path.exists(note):
                os.remove(note)
            os.rmdir(lease)
            open(lease, "a").close()
        _fsync_dir(data_dir)
        return dict(summary(source), restored=SQLITE_NAME)
    finally:
        owner.close()


def empty_postgres(data_dir, database_url):
    """Only on a rolled-back volume (a SQLite store present): the database's
    stale copy goes, so the next sqlite-to-postgres starts from empty."""
    if not os.path.isfile(os.path.join(data_dir, SQLITE_NAME)):
        raise Refused("no_sqlite_store")
    owner = Ownership(data_dir, database_url)
    try:
        backend = PostgresBackend(owner.conn)
        before = {table: len(rows) for table, rows in read_all(backend.execute).items()}
        backend.begin()
        for table in TABLES:
            owner.conn.execute(f"DELETE FROM {table}")
        backend.commit()
        return {"deleted": before}
    finally:
        owner.close()


def _fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


COMMANDS = {"sqlite-to-postgres": sqlite_to_postgres, "postgres-to-sqlite": postgres_to_sqlite,
            "empty-postgres": empty_postgres}


def main(argv=None, env=os.environ):
    parser = argparse.ArgumentParser(prog="python -m connector.migrate", description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=sorted(COMMANDS))
    parser.add_argument("--data-dir", default=env.get("COMMS_DATA_DIR", "/data"))
    parser.add_argument("--yes-delete-the-postgres-copy", action="store_true",
                        help="required by empty-postgres")
    args = parser.parse_args(argv)
    url = env.get("COMMS_DATABASE_URL", "")
    if not url.startswith(("postgresql://", "postgres://")):
        print(json.dumps({"refused": "database_url"}))
        return 2
    if args.command == "empty-postgres" and not args.yes_delete_the_postgres_copy:
        print(json.dumps({"refused": "confirm_with_--yes-delete-the-postgres-copy"}))
        return 2
    try:
        result = COMMANDS[args.command](args.data_dir, url)
    except Refused as refused:
        print(json.dumps({"refused": str(refused)}))
        return 2
    print(json.dumps(dict(result, done=args.command), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
