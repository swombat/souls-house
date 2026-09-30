"""Durable acceptance, not fire-and-forget.

One shim owns this ledger. On owner loss, nonterminal turns become unknown,
never replayed: their tools may already have had external effects. Unknown
turns retain their session reservation until an operator verifies containment.
"""
import fcntl
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import threading
import time
import uuid


class Conflict(Exception):
    pass


class TurnStore:
    def __init__(self, directory, execute):
        directory = Path(directory)
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.owner = open(directory / "owner.lock", "a")
        try:
            fcntl.flock(self.owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except Exception:
            self.owner.close()
            raise
        self.path = directory / "turns.sqlite3"
        self.execute = execute
        self.lock = threading.RLock()
        self.cancellations = {}
        with self.connect() as db:
            db.execute("CREATE TABLE IF NOT EXISTS metadata (id TEXT PRIMARY KEY)")
            row = db.execute("SELECT id FROM metadata").fetchone()
            self.ledger_id = row[0] if row else str(uuid.uuid4())
            if row is None:
                db.execute("INSERT INTO metadata VALUES (?)", (self.ledger_id,))
            db.execute("""CREATE TABLE IF NOT EXISTS turns (
                id TEXT PRIMARY KEY, digest TEXT NOT NULL, session TEXT NOT NULL,
                state TEXT NOT NULL, updated REAL NOT NULL, result TEXT)""")
            db.execute("UPDATE turns SET state = 'unknown' WHERE state IN ('accepted', 'running')")
        os.chmod(self.path, 0o600)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=5)
        try:
            with db:
                yield db
        finally:
            db.close()

    def status(self, turn_id):
        with self.connect() as db:
            row = db.execute("SELECT state, updated, result FROM turns WHERE id = ?", (turn_id,)).fetchone()
        if row is None:
            return None
        return {"id": turn_id, "ledger_id": self.ledger_id, "state": row[0], "updated_at": row[1],
                "result": json.loads(row[2]) if row[2] else None}

    def submit(self, turn_id, payload):
        if not re.fullmatch(r"[0-9a-f-]{36}", turn_id):
            raise ValueError("turn id must be a UUID")
        session = payload.get("session_id")
        if not isinstance(session, str) or not session or not isinstance(payload.get("request"), str) or not payload["request"]:
            raise ValueError("session_id and request are required")
        digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
        with self.lock, self.connect() as db:
            existing = db.execute("SELECT digest FROM turns WHERE id = ?", (turn_id,)).fetchone()
            if existing:
                if existing[0] != digest:
                    raise Conflict("turn id reused with different payload")
                return self.status(turn_id)
            if db.execute("SELECT 1 FROM turns WHERE session = ? AND state IN ('accepted', 'running', 'unknown')", (session,)).fetchone():
                raise Conflict("session already reserved")
            # Commit acceptance before launching. A crash in between is unknown,
            # not permission to launch it again.
            db.execute("INSERT INTO turns VALUES (?, ?, ?, 'accepted', ?, NULL)",
                       (turn_id, digest, session, time.time()))
            db.commit()
            cancel = threading.Event()
            self.cancellations[turn_id] = cancel
            threading.Thread(target=self.run, args=(turn_id, payload, cancel), daemon=True).start()
        return self.status(turn_id)

    def cancel(self, turn_id, payload=None):
        with self.lock, self.connect() as db:
            if payload is not None and self.status(turn_id) is None:
                if not re.fullmatch(r"[0-9a-f-]{36}", turn_id) or not isinstance(payload.get("session_id"), str):
                    raise ValueError("valid turn id and session_id required")
                digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
                result = {"status": 409, "body": {"status": "cancelled"}}
                db.execute("INSERT INTO turns VALUES (?, ?, ?, 'cancelled', ?, ?)",
                           (turn_id, digest, payload["session_id"], time.time(), json.dumps(result)))
                db.commit()
            event = self.cancellations.get(turn_id)
            if event:
                event.set()
        # Requesting cancellation is not proof of process exit.
        return self.status(turn_id)

    def run(self, turn_id, payload, cancel):
        with self.connect() as db:
            db.execute("UPDATE turns SET state = 'running', updated = ? WHERE id = ?", (time.time(), turn_id))
        stopped = threading.Event()

        def heartbeat():
            while not stopped.wait(10):
                with self.connect() as db:
                    db.execute("UPDATE turns SET updated = ? WHERE id = ? AND state = 'running'", (time.time(), turn_id))

        heartbeat_thread = threading.Thread(target=heartbeat, daemon=True)
        heartbeat_thread.start()
        try:
            result = self.execute(payload, cancel)
            state = "cancelled" if cancel.is_set() else "finished"
        except Exception:
            # Do not expose prompts/credentials from exception strings; an
            # exception is not proof that subprocesses or side effects stopped.
            state, result = "unknown", None
        finally:
            stopped.set()
            heartbeat_thread.join()
        with self.lock, self.connect() as db:
            db.execute("UPDATE turns SET state = ?, result = ?, updated = ? WHERE id = ?",
                       (state, json.dumps(result) if result else None, time.time(), turn_id))
            db.commit()
            self.cancellations.pop(turn_id, None)

    def resolve(self, turn_id):
        """Operator attestation AFTER verified containment; never automatic."""
        with self.lock, self.connect() as db:
            db.execute("""UPDATE turns SET state = 'cancelled', updated = ?, result = ?
                          WHERE id = ? AND state = 'unknown'""",
                       (time.time(), json.dumps({"status": 409, "body": {"status": "cancelled"}}), turn_id))
        return self.status(turn_id)
