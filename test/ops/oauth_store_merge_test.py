"""ops/chaos-home/oauth_store_merge.sql against a real PostgreSQL with dblink.

Needs a server reachable through the usual libpq environment (PGHOST, PGUSER,
...), with permission to create databases and the dblink extension. Without
one the tests skip, unless HOUSE_MERGE_TEST_REQUIRE_PG=1 (CI), where a missing
server is a failure.
"""
import hashlib
import os
import shutil
import subprocess
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MERGE_SQL = ROOT / "ops" / "chaos-home" / "oauth_store_merge.sql"
SCHEMA = ROOT / "test" / "fixtures" / "files" / "chaos_pg_schema.sql"
PSQL = shutil.which("psql")


def psql(db, sql=None, *, file=None, variables=(), check=True):
    args = [PSQL, "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-d", db]
    for name, value in variables:
        args += ["-v", f"{name}={value}"]
    if file is not None:
        args += ["--single-transaction", "-f", str(file)]
    else:
        args += ["-c", sql]
    result = subprocess.run(args, capture_output=True, text=True, timeout=120)
    if check and result.returncode:
        raise AssertionError(f"psql failed: {result.stderr}")
    return result


def server_available():
    if PSQL is None:
        return False
    try:
        return psql("postgres", "SELECT 1", check=False).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


AVAILABLE = server_available()
if not AVAILABLE and os.environ.get("HOUSE_MERGE_TEST_REQUIRE_PG") == "1":
    raise RuntimeError("HOUSE_MERGE_TEST_REQUIRE_PG=1 but no PostgreSQL is reachable")


def chaos_store(name, migrations=38):
    psql("postgres", f"DROP DATABASE IF EXISTS {name}")
    psql("postgres", f"CREATE DATABASE {name}")
    psql(name, file=SCHEMA)
    psql(name, """
        CREATE TABLE _sqlx_migrations (version BIGINT PRIMARY KEY, description TEXT NOT NULL,
            installed_on TIMESTAMPTZ NOT NULL DEFAULT now(), success BOOLEAN NOT NULL,
            checksum BYTEA NOT NULL, execution_time BIGINT NOT NULL)""")
    for version in range(1, migrations + 1):
        digest = hashlib.sha384(f"migration {version}".encode()).hexdigest()
        psql(name, f"INSERT INTO _sqlx_migrations VALUES ({version}, 'm', now(), true, "
                   f"'\\x{digest}', 1)")


def add_process(db, pid, parent=None, journal=3, created=100):
    parent_sql = "NULL, NULL" if parent is None else f"'{parent}', 1"
    psql(db, f"""
        INSERT INTO processes (id, parent_process_id, fork_at_seq, source, source_json, cwd, created_at, updated_at, title)
        VALUES ('{pid}', {parent_sql}, 'cli', '{{"k": "{pid}"}}', '/w', {created}, {created}, 'thread {pid}')""")
    for seq in range(1, journal + 1):
        psql(db, f"""
            INSERT INTO journal_entries (process_id, seq, recorded_at, item_type, payload_json)
            VALUES ('{pid}', {seq}, {created + seq}, 'response_item',
                    '{{"text": "{pid} line {seq}", "n": {seq}}}')""")


def scalar(db, sql):
    return psql(db, sql).stdout.strip()


@unittest.skipUnless(AVAILABLE, "no PostgreSQL with create-database rights")
class OauthStoreMergeTest(unittest.TestCase):
    def setUp(self):
        tag = uuid.uuid4().hex[:8]
        self.src = f"merge_src_{tag}"
        self.dst = f"merge_dst_{tag}"
        chaos_store(self.src)
        chaos_store(self.dst)

    def tearDown(self):
        for db in (self.src, self.dst):
            psql("postgres", f"DROP DATABASE IF EXISTS {db} WITH (FORCE)", check=False)

    def merge(self, check=True):
        return psql(self.dst, file=MERGE_SQL, variables=[("src", self.src)], check=check)

    def populate(self):
        # Main home: its own sessions and settings.
        add_process(self.dst, "main-1")
        psql(self.dst, "INSERT INTO settings (key, value) VALUES ('model', 'main')")
        psql(self.dst, "INSERT INTO message_history (conversation_id, ts, text, estimated_bytes) "
                       "VALUES ('c', 1, 'main typed this', 15)")
        # Subscription home: a parent and a forked child, a lease, history, a cache row.
        add_process(self.src, "sub-parent", journal=5)
        add_process(self.src, "sub-child", parent="sub-parent", journal=2, created=200)
        psql(self.src, "INSERT INTO process_leases (process_id, owner_id, expires_at, updated_at) "
                       "VALUES ('sub-parent', 'runner', 10, 10)")
        psql(self.src, "INSERT INTO settings (key, value) VALUES ('model', 'oauth')")
        psql(self.src, "INSERT INTO message_history (conversation_id, ts, text, estimated_bytes) "
                       "VALUES ('c', 2, 'oauth typed this', 16)")
        psql(self.src, "INSERT INTO ration_usage (provider, base_url, label, utilization, observed_at) "
                       "VALUES ('openai', 'https://x', 'weekly', 0.5, 50)")

    def test_carries_sessions_keeps_main_state_and_records_the_marker(self):
        self.populate()
        result = self.merge()
        self.assertIn("merged 2 processes, 7 journal rows", result.stderr)
        self.assertEqual(scalar(self.dst, "SELECT string_agg(id, ',' ORDER BY id) FROM processes"),
                         "main-1,sub-child,sub-parent")
        self.assertEqual(scalar(self.dst, "SELECT count(*) FROM journal_entries WHERE process_id LIKE 'sub-%'"), "7")
        # Lineage is rebuilt by Chaos's own trigger, identical to the source's.
        self.assertEqual(
            scalar(self.dst, "SELECT string_agg(ancestor_process_id||'>'||descendant_process_id||':'||depth, ',' "
                             "ORDER BY 1) FROM process_closure WHERE descendant_process_id LIKE 'sub-%'"),
            scalar(self.src, "SELECT string_agg(ancestor_process_id||'>'||descendant_process_id||':'||depth, ',' "
                             "ORDER BY 1) FROM process_closure"))
        self.assertEqual(scalar(self.dst, "SELECT owner_id FROM process_leases WHERE process_id = 'sub-parent'"),
                         "runner")
        # The main home's settings win; the subscription's stay behind.
        self.assertEqual(scalar(self.dst, "SELECT value FROM settings WHERE key = 'model'"), "main")
        self.assertEqual(scalar(self.dst, "SELECT string_agg(text, '|' ORDER BY id) FROM message_history"),
                         "main typed this|oauth typed this")
        self.assertEqual(scalar(self.dst, "SELECT utilization FROM ration_usage"), "0.5")
        self.assertEqual(scalar(self.dst, "SELECT processes || ' ' || journal_entries FROM house_oauth_store_merges"),
                         "2 7")
        # The source is only read.
        self.assertEqual(scalar(self.src, "SELECT count(*) FROM processes"), "2")

    def test_a_second_run_changes_nothing(self):
        self.populate()
        self.merge()
        before = scalar(self.dst, "SELECT (SELECT count(*) FROM processes) || ' ' || "
                                  "(SELECT count(*) FROM journal_entries) || ' ' || (SELECT count(*) FROM message_history)")
        result = self.merge()
        self.assertIn("already merged", result.stderr)
        after = scalar(self.dst, "SELECT (SELECT count(*) FROM processes) || ' ' || "
                                 "(SELECT count(*) FROM journal_entries) || ' ' || (SELECT count(*) FROM message_history)")
        self.assertEqual(before, after)
        self.assertEqual(scalar(self.dst, "SELECT count(*) FROM house_oauth_store_merges"), "1")

    def test_a_shared_process_id_refuses_with_nothing_written(self):
        self.populate()
        add_process(self.dst, "sub-parent", journal=1)
        result = self.merge(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("1 source process ids already exist", result.stderr)
        self.assertEqual(scalar(self.dst, "SELECT count(*) FROM processes"), "2")
        self.assertEqual(scalar(self.dst, "SELECT count(*) FROM message_history"), "1")
        self.assertEqual(scalar(self.dst, "SELECT to_regclass('house_oauth_store_merges') IS NULL"), "t")

    def test_an_interrupted_merge_leaves_nothing_and_can_be_retried(self):
        self.populate()
        # Fail part-way: after processes are in, on the first journal row.
        psql(self.dst, """
            CREATE FUNCTION fail_once() RETURNS trigger LANGUAGE plpgsql AS
            $$ BEGIN IF NEW.process_id LIKE 'sub-%' THEN RAISE EXCEPTION 'injected crash'; END IF;
               RETURN NEW; END $$;
            CREATE TRIGGER fail_once BEFORE INSERT ON journal_entries FOR EACH ROW EXECUTE FUNCTION fail_once();""")
        result = self.merge(check=False)
        self.assertIn("injected crash", result.stderr)
        self.assertEqual(scalar(self.dst, "SELECT count(*) FROM processes"), "1")
        self.assertEqual(scalar(self.dst, "SELECT count(*) FROM process_closure"), "1")
        self.assertEqual(scalar(self.dst, "SELECT to_regclass('house_oauth_store_merges') IS NULL"), "t")
        self.assertEqual(scalar(self.dst, "SELECT count(*) FROM pg_extension WHERE extname = 'dblink'"), "0")
        psql(self.dst, "DROP TRIGGER fail_once ON journal_entries")
        self.merge()
        self.assertEqual(scalar(self.dst, "SELECT count(*) FROM processes"), "3")

    def test_a_row_that_arrives_altered_refuses(self):
        self.populate()
        psql(self.dst, """
            CREATE FUNCTION alter_payload() RETURNS trigger LANGUAGE plpgsql AS
            $$ BEGIN NEW.payload_json := NEW.payload_json || '{"x": 1}'; RETURN NEW; END $$;
            CREATE TRIGGER alter_payload BEFORE INSERT ON journal_entries FOR EACH ROW EXECUTE FUNCTION alter_payload();""")
        result = self.merge(check=False)
        self.assertIn("journal_entries arrived different from its source", result.stderr)
        self.assertEqual(scalar(self.dst, "SELECT count(*) FROM processes"), "1")

    def test_an_unclassified_table_with_rows_refuses(self):
        self.populate()
        psql(self.src, "CREATE TABLE brand_new_state (x INT); INSERT INTO brand_new_state VALUES (1)")
        result = self.merge(check=False)
        self.assertIn("brand_new_state (1 rows) is not classified", result.stderr)
        self.assertEqual(scalar(self.dst, "SELECT count(*) FROM processes"), "1")

    def test_an_empty_unclassified_table_is_no_obstacle(self):
        self.populate()
        psql(self.src, "CREATE TABLE brand_new_state (x INT)")
        self.merge()
        self.assertEqual(scalar(self.dst, "SELECT count(*) FROM processes"), "3")

    def test_planning_rows_refuse(self):
        self.populate()
        psql(self.src, "INSERT INTO planning_workspaces (id, code, name) VALUES ('w', 'ABC123', 'w')")
        result = self.merge(check=False)
        self.assertIn("planning_workspaces has 1 rows", result.stderr)

    def test_different_migrations_refuse_when_there_is_something_to_carry(self):
        self.populate()
        psql(self.src, "DELETE FROM _sqlx_migrations WHERE version = 38")
        result = self.merge(check=False)
        self.assertIn("migrations differ", result.stderr)

    def test_an_empty_source_is_only_marked_even_on_an_older_schema(self):
        add_process(self.dst, "main-1")
        psql(self.src, "DELETE FROM _sqlx_migrations WHERE version = 38")
        self.merge()
        self.assertEqual(scalar(self.dst, "SELECT processes FROM house_oauth_store_merges"), "0")
        self.assertEqual(scalar(self.dst, "SELECT count(*) FROM processes"), "1")

    def test_a_rate_limit_reading_is_replaced_only_by_a_newer_one(self):
        self.populate()
        psql(self.dst, "INSERT INTO ration_usage (provider, base_url, label, utilization, observed_at) "
                       "VALUES ('openai', 'https://x', 'weekly', 0.9, 90)")
        self.merge()
        self.assertEqual(scalar(self.dst, "SELECT utilization FROM ration_usage"), "0.9")

    def test_dblink_already_installed_is_left_installed(self):
        self.populate()
        psql(self.dst, "CREATE EXTENSION dblink")
        self.merge()
        self.assertEqual(scalar(self.dst, "SELECT count(*) FROM pg_extension WHERE extname = 'dblink'"), "1")

    def test_dblink_created_by_the_merge_is_removed(self):
        self.populate()
        self.merge()
        self.assertEqual(scalar(self.dst, "SELECT count(*) FROM pg_extension WHERE extname = 'dblink'"), "0")


if __name__ == "__main__":
    unittest.main()
