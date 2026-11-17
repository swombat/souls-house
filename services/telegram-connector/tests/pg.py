"""Postgres for the tests: a fresh database per use, dropped afterwards.

COMMS_TEST_DATABASE_URL names a server and a database to administer from
(postgresql://user:password@host:port/postgres). Without it the Postgres
tests skip, unless COMMS_TEST_REQUIRE_POSTGRES=1 (CI), where a missing
server is a failure. COMMS_TEST_STORE=postgres runs the Harness suite (every
account, replay and process test that uses it) on Postgres instead of SQLite.
"""

import os
import unittest
import urllib.parse
import uuid

ADMIN_URL = os.environ.get("COMMS_TEST_DATABASE_URL", "")
REQUIRED = os.environ.get("COMMS_TEST_REQUIRE_POSTGRES") == "1"
HARNESS_ON_POSTGRES = os.environ.get("COMMS_TEST_STORE") == "postgres"


def skip_unless_postgres(cls_or_fn):
    if ADMIN_URL:
        return cls_or_fn
    if REQUIRED:
        raise RuntimeError("COMMS_TEST_REQUIRE_POSTGRES=1 but COMMS_TEST_DATABASE_URL is not set")
    return unittest.skip("COMMS_TEST_DATABASE_URL not set")(cls_or_fn)


def _admin():
    import psycopg
    return psycopg.connect(ADMIN_URL, autocommit=True)


class Database:
    def __init__(self):
        self.name = "tgtest_" + uuid.uuid4().hex[:12]
        with _admin() as conn:
            conn.execute(f'CREATE DATABASE "{self.name}"')
        parts = urllib.parse.urlsplit(ADMIN_URL)
        self.url = urllib.parse.urlunsplit(parts._replace(path="/" + self.name))

    def drop(self):
        with _admin() as conn:
            conn.execute("SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                         "WHERE datname = %s AND pid <> pg_backend_pid()", (self.name,))
            conn.execute(f'DROP DATABASE IF EXISTS "{self.name}"')

    def terminate_connections(self, application_name="comms-telegram"):
        """Kills the connector's backends, as a server restart or an
        administrator would. Returns how many."""
        with _admin() as conn:
            rows = conn.execute("SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                                "WHERE datname = %s AND application_name = %s",
                                (self.name, application_name)).fetchall()
        return len(rows)
