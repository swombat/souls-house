"""ops/chaos-home/merge_oauth_store.py: the docker plumbing around the SQL.

A fake `docker` stands in for the host: container state, the chaos-home
volume's files, and the main database's marker table.
"""
import importlib.util
import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("merge_oauth_store", ROOT / "ops" / "chaos-home" / "merge_oauth_store.py")
merge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(merge)

AGENT = "019f88e5-4b53-7047-94e3-2873fad1821d"
SECRET = "s3cret-password"
MAIN = f'storage_url = "postgres://main_user:{SECRET}@pg:5432/main_db"\n'
OAUTH = f'storage_url = "postgres://oauth_user:{SECRET}@pg:5432/oauth_db"\n'


class FakeHost:
    def __init__(self, running=False, files=None, merged=False, sql_fails=False):
        self.running = running
        self.files = {"config.toml": MAIN, "oauth-runtime/config.toml": OAUTH} if files is None else files
        self.merged = merged
        self.sql_fails = sql_fails
        self.calls = []

    def __call__(self, *args, input=None, check=True):
        self.calls.append((args, input))
        ok = lambda out="", err="": subprocess.CompletedProcess(args, 0, out, err)
        if args[0] == "inspect":
            return ok(json.dumps([{"State": {"Running": self.running}, "Image": "sha256:img",
                                    "Config": {"Env": ["A=b"]}}]))
        if args[0] == "run":
            command = list(args[args.index("--entrypoint") + 1:])
            if command[0] == "cat":
                path = command[2][len("/c/"):]
                if path in self.files:
                    return ok(self.files[path])
                return subprocess.CompletedProcess(args, 1, "", "No such file")
            if command[0] == "mv":
                assert ":ro" not in args[args.index("-v") + 1]
                src, dst = command[2][len("/c/"):], command[3][len("/c/"):]
                self.files[dst] = self.files.pop(src)
                return ok()
        if args[:3] == ("exec", "souls-house-postgres", "printenv"):
            return ok("postgres\n")
        if args[0] == "exec":
            if (input or "").strip() == "SELECT to_regclass('house_oauth_store_merges') IS NOT NULL;":
                return ok("t\n" if self.merged else "f\n")
            if (input or "").startswith("SELECT processes"):
                return ok("12 345\n" if self.merged else "")
            if (input or "").startswith("BEGIN;"):
                if self.sql_fails:
                    if check:
                        raise merge.Refused("docker exec failed: ERROR: 1 source process ids already exist")
                if input.rstrip().endswith("COMMIT;"):
                    self.merged = True
                return ok("", "NOTICE:  house_oauth_store_merge: merged 12 processes")
        raise AssertionError(f"unexpected docker call {args}")


class MergeDriverTest(unittest.TestCase):
    def go(self, host, dry_run=False):
        lines = []
        code = merge.Merge(AGENT, run=host, out=lines.append)(dry_run=dry_run)
        return code, "\n".join(lines)

    def all_args(self, host):
        return " ".join(" ".join(a) + (i or "") for a, i in host.calls)

    def test_merges_then_moves_the_config_aside(self):
        host = FakeHost()
        code, out = self.go(host)
        self.assertEqual(code, 0)
        self.assertIn("source oauth_db -> destination main_db", out)
        self.assertIn("merged: 12 processes, 345 journal rows", out)
        self.assertNotIn("oauth-runtime/config.toml", host.files)
        self.assertIn(f"oauth-runtime/{merge.MOVED_NAME}", host.files)
        merge_call = next(a for a, i in host.calls if i and i.startswith("BEGIN;"))
        self.assertIn("src=oauth_db", merge_call)
        self.assertIn("main_db", merge_call)

    def test_no_connection_string_reaches_arguments_input_or_output(self):
        host = FakeHost()
        _, out = self.go(host)
        self.assertNotIn(SECRET, self.all_args(host))
        self.assertNotIn(SECRET, out)
        self.assertNotIn("postgres://", out)

    def test_running_container_refuses_before_reading_anything(self):
        host = FakeHost(running=True)
        with self.assertRaises(merge.Refused):
            self.go(host)
        self.assertEqual([a[0] for a, _ in host.calls], ["inspect"])

    def test_failed_merge_leaves_the_config_in_place(self):
        host = FakeHost(sql_fails=True)
        with self.assertRaises(merge.Refused):
            self.go(host)
        self.assertIn("oauth-runtime/config.toml", host.files)

    def test_retry_after_commit_only_moves(self):
        host = FakeHost(merged=True)
        code, out = self.go(host)
        self.assertEqual(code, 0)
        self.assertFalse(any(i and i.startswith("BEGIN;") for _, i in host.calls))
        self.assertIn(f"oauth-runtime/{merge.MOVED_NAME}", host.files)

    def test_dry_run_rolls_back_and_never_moves(self):
        host = FakeHost()
        code, out = self.go(host, dry_run=True)
        self.assertEqual(code, 0)
        sent = next(i for _, i in host.calls if i and i.startswith("BEGIN;"))
        self.assertTrue(sent.rstrip().endswith("ROLLBACK;"))
        self.assertIn("oauth-runtime/config.toml", host.files)

    def test_already_moved_is_nothing_to_do(self):
        host = FakeHost(files={"config.toml": MAIN, f"oauth-runtime/{merge.MOVED_NAME}": OAUTH})
        code, out = self.go(host)
        self.assertEqual(code, 0)
        self.assertIn("already merged and moved aside", out)

    def test_new_home_without_an_oauth_store_is_nothing_to_do(self):
        host = FakeHost(files={"config.toml": MAIN})
        _, out = self.go(host)
        self.assertIn("names no store of its own", out)

    def test_stores_on_different_servers_refuse(self):
        host = FakeHost(files={"config.toml": MAIN,
                               "oauth-runtime/config.toml": OAUTH.replace("@pg:", "@elsewhere:")})
        with self.assertRaisesRegex(merge.Refused, "different servers"):
            self.go(host)

    def test_sqlite_source_refuses(self):
        host = FakeHost(files={"config.toml": MAIN,
                               "oauth-runtime/config.toml": 'storage_url = "sqlite:///c/chaos.sqlite"\n'})
        with self.assertRaisesRegex(merge.Refused, "not PostgreSQL"):
            self.go(host)

    def test_env_reference_is_resolved_from_the_container(self):
        self.assertEqual(merge.store_location('storage_url = "env:X"\n', {"X": "postgres://u:p@pg/db_x"}),
                         (("pg", 5432), "db_x"))

    def test_agent_must_be_a_uuid(self):
        with self.assertRaises(merge.Refused):
            merge.Merge("hk-agent-x; rm -rf /")


if __name__ == "__main__":
    unittest.main()
