"""Contract tests for public/cli/souls, against a local fake house.

Run: python3 -m unittest discover -s test/cli -p '*_test.py'
"""

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import stat
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(ROOT, "public", "cli", "souls")


def load_cli():
    loader = importlib.machinery.SourceFileLoader("souls_cli", SCRIPT)
    spec = importlib.util.spec_from_loader("souls_cli", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


souls = load_cli()


class FakeHouse:
    """Records every request; answers from a route table of (method, path) -> (status, body, headers)."""

    def __init__(self):
        self.requests = []
        self.routes = {}
        house = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _handle(self):
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length) if length else b""
                path, _, query = self.path.partition("?")
                house.requests.append({
                    "method": self.command, "path": path, "query": query,
                    "headers": {k.lower(): v for k, v in self.headers.items()}, "body": body,
                })
                route = house.routes.get((self.command, path))
                if callable(route):
                    route = route(house.requests[-1])
                status, payload, headers = route or (404, {"error": "Not found"}, {})
                data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
                stall = headers.pop("X-Test-Stall-Body", None)
                self.send_response(status)
                for k, v in headers.items():
                    self.send_header(k, v)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                if stall:
                    time.sleep(float(stall))
                try:
                    self.wfile.write(data)
                except OSError:
                    pass

            do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = _handle

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()

    def route(self, method, path, status=200, body=None, headers=None):
        fixed = (status, {} if body is None else body, dict(headers or {}))
        self.routes[(method, path)] = lambda req: (fixed[0], fixed[1], dict(fixed[2]))

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class CliTestCase(unittest.TestCase):
    def setUp(self):
        self.house = FakeHouse()
        self.addCleanup(self.house.close)
        self.config_dir = tempfile.mkdtemp()
        self.env = {"XDG_CONFIG_HOME": self.config_dir, "SOULS_TOKEN": "hx_test", "SOULS_URL": self.house.url}

    def run_cli(self, *argv, stdin="", env=None, tty=False):
        environ = {k: v for k, v in os.environ.items()
                   if not k.startswith(("SOULS_", "SOULSHOUSE_"))}
        environ.update(self.env if env is None else env)
        out, err = io.StringIO(), io.StringIO()
        fake_stdin = io.StringIO(stdin)
        fake_stdin.isatty = lambda: tty
        with mock.patch.dict(os.environ, environ, clear=True), \
                mock.patch.object(sys, "stdin", fake_stdin), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = souls.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def last(self):
        return self.house.requests[-1]


class PostingTest(CliTestCase):
    def test_stdin_text_is_sent_literally_with_the_bearer(self):
        self.house.route("POST", "/api/v1/conversations/c1/messages", body={"message": {"id": "m1"}})
        code, out, _ = self.run_cli("post", "c1", stdin="Price is $5 and `rm -rf` stays text\n")
        self.assertEqual(code, 0)
        req = self.last()
        self.assertEqual(req["headers"]["authorization"], "Bearer hx_test")
        self.assertEqual(json.loads(req["body"]), {"content": "Price is $5 and `rm -rf` stays text"})
        self.assertEqual(json.loads(out)["message"]["id"], "m1")

    def test_attachments_go_as_one_multipart_request(self):
        self.house.route("POST", "/api/v1/conversations/c1/messages", body={"message": {"id": "m1"}})
        path = os.path.join(self.config_dir, "pic.png")
        with open(path, "wb") as fh:
            fh.write(b"\x89PNG fake")
        code, _, _ = self.run_cli("post", "c1", "caption", "--attach", path)
        self.assertEqual(code, 0)
        req = self.last()
        self.assertTrue(req["headers"]["content-type"].startswith("multipart/form-data; boundary="))
        self.assertIn(b'name="content"\r\n\r\ncaption', req["body"])
        self.assertIn(b'name="files[]"; filename="pic.png"\r\nContent-Type: image/png', req["body"])
        self.assertIn(b"\x89PNG fake", req["body"])

    def test_nothing_to_post_is_a_usage_error_without_a_request(self):
        code, _, err = self.run_cli("post", "c1", tty=True)
        self.assertEqual(code, souls.EXIT_USAGE)
        self.assertEqual(self.house.requests, [])
        self.assertIn("nothing to post", err)

    def test_account_option_works_before_or_after_the_command(self):
        self.house.route("GET", "/api/v1/conversations", body={"conversations": [], "next_cursor": None})
        for argv in (("--account", "A1", "rooms"), ("rooms", "--account", "A1")):
            self.run_cli(*argv)
            self.assertIn("account_id=A1", self.last()["query"])


class CredentialTest(CliTestCase):
    def test_souls_token_beats_the_resident_environment(self):
        self.house.route("GET", "/api/v1/session", body={"actor": {}})
        env = dict(self.env, SOULSHOUSE_BEARER_TOKEN="hx_resident", SOULSHOUSE_APP_URL="http://unused")
        self.run_cli("whoami", env=env)
        self.assertEqual(self.last()["headers"]["authorization"], "Bearer hx_test")

    def test_resident_environment_is_used_when_nothing_else_is_set(self):
        self.house.route("GET", "/api/v1/session", body={"actor": {}})
        env = {"XDG_CONFIG_HOME": self.config_dir, "SOULSHOUSE_BEARER_TOKEN": "hx_resident",
               "SOULSHOUSE_APP_URL": self.house.url}
        self.run_cli("whoami", env=env)
        self.assertEqual(self.last()["headers"]["authorization"], "Bearer hx_resident")

    def test_login_checks_the_key_and_saves_a_private_profile(self):
        self.house.route("GET", "/api/v1/session", body={"actor": {"id": "u1", "name": "Ada"}})
        env = {"XDG_CONFIG_HOME": self.config_dir}
        code, _, err = self.run_cli("login", "--url", self.house.url, "--profile", "work", stdin="hx_saved\n", env=env)
        self.assertEqual(code, 0)
        self.assertEqual(self.last()["headers"]["authorization"], "Bearer hx_saved")
        path = os.path.join(self.config_dir, "souls", "config.json")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertIn("Ada", err)
        # The saved profile is then used, and --profile wins over SOULS_TOKEN.
        self.run_cli("whoami", "--profile", "work", env=dict(env, SOULS_TOKEN="hx_env"))
        self.assertEqual(self.last()["headers"]["authorization"], "Bearer hx_saved")

    def test_a_rejected_key_is_not_saved(self):
        self.house.route("GET", "/api/v1/session", status=401, body={"error": "Invalid API key"})
        env = {"XDG_CONFIG_HOME": self.config_dir}
        code, _, _ = self.run_cli("login", "--url", self.house.url, stdin="hx_bad\n", env=env)
        self.assertEqual(code, souls.EXIT_AUTH)
        self.assertFalse(os.path.exists(os.path.join(self.config_dir, "souls", "config.json")))

    def test_no_credential_is_an_auth_error_without_a_request(self):
        code, _, err = self.run_cli("rooms", env={"XDG_CONFIG_HOME": self.config_dir})
        self.assertEqual(code, souls.EXIT_AUTH)
        self.assertIn("souls login", err)


class ErrorTest(CliTestCase):
    def test_status_codes_map_to_exit_codes_and_keep_the_house_message(self):
        cases = [(403, souls.EXIT_AUTH), (404, souls.EXIT_NOT_FOUND), (409, souls.EXIT_CONFLICT),
                 (422, souls.EXIT_INVALID), (500, souls.EXIT_ERROR)]
        for status, expected in cases:
            self.house.route("GET", "/api/v1/session", status=status, body={"error": f"says {status}"})
            code, out, err = self.run_cli("whoami")
            self.assertEqual(code, expected, status)
            self.assertEqual(out, "")
            self.assertIn(f"HTTP {status}: says {status}", err)

    def test_an_unreachable_house_is_a_network_error(self):
        env = dict(self.env, SOULS_URL="http://127.0.0.1:9")
        code, _, err = self.run_cli("whoami", env=env)
        self.assertEqual(code, souls.EXIT_NETWORK)
        self.assertIn("could not reach", err)


class ReadingTest(CliTestCase):
    def test_rooms_follows_next_cursor(self):
        def page(req):
            if "cursor=p2" in req["query"]:
                return 200, {"conversations": [{"id": "c2", "title": "Two"}], "next_cursor": None}, {}
            return 200, {"conversations": [{"id": "c1", "title": "One"}], "next_cursor": "p2"}, {}
        self.house.routes[("GET", "/api/v1/conversations")] = page
        code, out, _ = self.run_cli("rooms", "--all", "--json")
        self.assertEqual([c["id"] for c in json.loads(out)["conversations"]], ["c1", "c2"])

    def test_download_does_not_carry_the_bearer_to_storage(self):
        storage = FakeHouse()
        self.addCleanup(storage.close)
        storage.route("GET", "/blob", body=b"file bytes")
        self.house.route("GET", "/api/v1/conversations/c1/messages/m1/attachments/9", status=302,
                         body=b"", headers={"Location": storage.url + "/blob"})
        target = os.path.join(self.config_dir, "out.bin")
        code, _, _ = self.run_cli("download", "/api/v1/conversations/c1/messages/m1/attachments/9", "-o", target)
        self.assertEqual(code, 0)
        with open(target, "rb") as fh:
            self.assertEqual(fh.read(), b"file bytes")
        self.assertEqual(self.house.requests[0]["headers"]["authorization"], "Bearer hx_test")
        self.assertNotIn("authorization", storage.requests[0]["headers"])

    def test_watch_prints_completed_changes_after_the_current_revision(self):
        calls = []

        def changes(req):
            calls.append(req["query"])
            if "since=0" in req["query"]:
                return 200, {"changes": [], "next_since": 0, "has_more": False, "latest_revision": 7}, {}
            return 200, {"changes": [
                {"id": "m8", "revision": 8, "content": "still writing", "completed": False, "author": {"name": "Mira"}},
                {"id": "m9", "revision": 9, "content": "done", "completed": True, "author": {"name": "Mira"}},
            ], "next_since": 9, "has_more": False, "latest_revision": 9}, {}
        self.house.routes[("GET", "/api/v1/conversations/c1/changes")] = changes
        code, out, _ = self.run_cli("watch", "c1", "--once", "--interval", "0", "--json")
        self.assertEqual(code, 0)
        self.assertIn("since=7", calls[1])
        self.assertEqual([json.loads(line)["id"] for line in out.splitlines()], ["m9"])

    def test_watch_falls_back_to_the_transcript_for_resident_keys(self):
        self.house.route("GET", "/api/v1/conversations/c1/changes", status=403, body={"error": "person only"})

        def show(req):
            if "after_message_id=m1" in req["query"]:
                return 200, {"conversation": {"transcript": [{"id": "m2", "content": "new", "author": "Lume"}]}}, {}
            return 200, {"conversation": {"transcript": [{"id": "m1", "content": "old", "author": "Lume"}]}}, {}
        self.house.routes[("GET", "/api/v1/conversations/c1")] = show
        code, out, _ = self.run_cli("watch", "c1", "--once", "--interval", "0", "--json")
        self.assertEqual(code, 0)
        self.assertEqual([json.loads(line)["id"] for line in out.splitlines()], ["m2"])


class ApiEscapeHatchTest(CliTestCase):
    def test_api_sends_json_query_and_relative_paths(self):
        self.house.route("POST", "/api/v1/conversations/c1/stones", body={"stone": {"id": "s1"}})
        code, out, _ = self.run_cli("api", "post", "conversations/c1/stones", "-d", '{"title": "t"}', "-q", "x=1")
        self.assertEqual(code, 0)
        req = self.last()
        self.assertEqual(json.loads(req["body"]), {"title": "t"})
        self.assertEqual(req["query"], "x=1")
        self.assertEqual(json.loads(out)["stone"]["id"], "s1")

    def test_api_form_uploads_a_file(self):
        self.house.route("POST", "/api/v1/field/files", body={"file": {"id": "f1"}})
        path = os.path.join(self.config_dir, "notes.md")
        with open(path, "w") as fh:
            fh.write("# notes")
        self.run_cli("api", "POST", "field/files", "-F", f"file=@{path}", "-F", "title=Notes")
        body = self.last()["body"]
        self.assertIn(b'name="file"; filename="notes.md"', body)
        self.assertIn(b"# notes", body)
        self.assertIn(b'name="title"\r\n\r\nNotes', body)

    def test_invalid_json_data_is_a_usage_error(self):
        code, _, err = self.run_cli("api", "POST", "rhythms", "-d", "{nope")
        self.assertEqual(code, souls.EXIT_USAGE)
        self.assertEqual(self.house.requests, [])


class OriginTest(CliTestCase):
    def test_a_foreign_absolute_url_is_refused_before_any_request(self):
        elsewhere = FakeHouse()
        self.addCleanup(elsewhere.close)
        elsewhere.route("GET", "/steal", body={"ok": True})
        for argv in (("api", "GET", elsewhere.url + "/steal"),
                     ("download", elsewhere.url + "/steal", "-o", os.path.join(self.config_dir, "x"))):
            code, _, err = self.run_cli(*argv)
            self.assertEqual(code, souls.EXIT_USAGE, argv)
            self.assertIn("refusing to send your credential", err)
        self.assertEqual(elsewhere.requests, [])
        self.assertEqual(self.house.requests, [])

    def test_origins_compare_parsed_parts_not_prefixes(self):
        client = souls.Client("https://souls.example", "hx")
        self.assertEqual(client.build_url("https://SOULS.example:443/api/v1/me"), "https://SOULS.example:443/api/v1/me")
        for foreign in ("https://souls.example.evil.test/api/v1/me", "http://souls.example/api/v1/me",
                        "https://souls.example:8443/api/v1/me", "https://evil.test/https://souls.example/"):
            with self.assertRaises(souls.CliError, msg=foreign):
                client.build_url(foreign)

    def test_a_same_origin_absolute_url_keeps_the_bearer(self):
        self.house.route("GET", "/api/v1/me", body={"user": {}})
        code, _, _ = self.run_cli("api", "GET", self.house.url + "/api/v1/me")
        self.assertEqual(code, 0)
        self.assertEqual(self.last()["headers"]["authorization"], "Bearer hx_test")


class LogoutLoginTest(CliTestCase):
    def save_profile(self, name, url, token, default=True):
        path = os.path.join(self.config_dir, "souls", "config.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        config = {"profiles": {}}
        if os.path.exists(path):
            with open(path) as fh:
                config = json.load(fh)
        config["profiles"][name] = {"url": url, "token": token}
        if default:
            config["default_profile"] = name
        with open(path, "w") as fh:
            json.dump(config, fh)
        return path

    def test_revoke_uses_the_removed_profile_not_the_ambient_credential(self):
        profile_house = FakeHouse()
        self.addCleanup(profile_house.close)
        profile_house.route("DELETE", "/api/v1/session", body={"revoked": True})
        path = self.save_profile("b", profile_house.url, "hx_profile_b")
        code, _, _ = self.run_cli("logout", "--revoke")  # SOULS_TOKEN=hx_test is ambient
        self.assertEqual(code, 0)
        self.assertEqual(self.house.requests, [])
        self.assertEqual(profile_house.requests[0]["method"], "DELETE")
        self.assertEqual(profile_house.requests[0]["headers"]["authorization"], "Bearer hx_profile_b")
        with open(path) as fh:
            self.assertNotIn("b", json.load(fh)["profiles"])

    def test_logout_of_a_missing_profile_sends_nothing(self):
        code, _, err = self.run_cli("logout", "--revoke", "--profile", "ghost")
        self.assertEqual(code, souls.EXIT_NOT_FOUND)
        self.assertEqual(self.house.requests, [])
        self.assertIn("ghost", err)

    def test_login_probes_and_saves_the_configured_self_hosted_url(self):
        self.house.route("GET", "/api/v1/session", body={"actor": {"name": "Ada"}})
        env = {"XDG_CONFIG_HOME": self.config_dir, "SOULS_TOKEN": "hx_self", "SOULS_URL": self.house.url}
        code, _, _ = self.run_cli("login", env=env)
        self.assertEqual(code, 0)
        self.assertEqual(self.last()["headers"]["authorization"], "Bearer hx_self")
        with open(os.path.join(self.config_dir, "souls", "config.json")) as fh:
            self.assertEqual(json.load(fh)["profiles"]["default"]["url"], self.house.url)

    def test_saving_never_writes_through_a_planted_temp_file(self):
        self.house.route("GET", "/api/v1/session", body={"actor": {}})
        directory = os.path.join(self.config_dir, "souls")
        os.makedirs(directory)
        victim = os.path.join(self.config_dir, "victim")
        with open(victim, "w") as fh:
            fh.write("untouched")
        os.symlink(victim, os.path.join(directory, "config.json.tmp"))
        env = {"XDG_CONFIG_HOME": self.config_dir, "SOULS_URL": self.house.url}
        code, _, _ = self.run_cli("login", stdin="hx_k\n", env=env)
        self.assertEqual(code, 0)
        with open(victim) as fh:
            self.assertEqual(fh.read(), "untouched")
        config = os.path.join(directory, "config.json")
        self.assertEqual(stat.S_IMODE(os.stat(config).st_mode), 0o600)
        self.assertEqual([n for n in os.listdir(directory) if n.startswith(".config-")], [])

    def test_a_malformed_config_is_a_short_usage_error(self):
        path = os.path.join(self.config_dir, "souls", "config.json")
        os.makedirs(os.path.dirname(path))
        with open(path, "w") as fh:
            fh.write("{not json")
        code, _, err = self.run_cli("rooms", env={"XDG_CONFIG_HOME": self.config_dir})
        self.assertEqual(code, souls.EXIT_USAGE)
        self.assertIn("cannot read", err)
        self.assertNotIn("Traceback", err)


class TransportTest(CliTestCase):
    def test_a_stalled_response_body_is_a_network_error_not_a_traceback(self):
        self.house.route("GET", "/api/v1/session", body={"actor": {}}, headers={"X-Test-Stall-Body": "1"})
        code, _, err = self.run_cli("whoami", env=dict(self.env, SOULS_HTTP_TIMEOUT="0.2"))
        self.assertEqual(code, souls.EXIT_NETWORK)
        self.assertNotIn("Traceback", err)


class CaptionTest(CliTestCase):
    def test_a_piped_caption_with_attachments_needs_dash_and_stays_literal(self):
        self.house.route("POST", "/api/v1/conversations/c1/messages", body={"message": {"id": "m1"}})
        path = os.path.join(self.config_dir, "a.txt")
        with open(path, "w") as fh:
            fh.write("x")
        code, _, _ = self.run_cli("post", "c1", "-", "--attach", path, stdin="Cost: $5 `now`\n")
        self.assertEqual(code, 0)
        self.assertIn(b'name="content"\r\n\r\nCost: $5 `now`\r\n', self.last()["body"])

    def test_attachment_only_post_never_reads_stdin(self):
        self.house.route("POST", "/api/v1/conversations/c1/messages", body={"message": {"id": "m1"}})
        path = os.path.join(self.config_dir, "a.txt")
        with open(path, "w") as fh:
            fh.write("x")

        class OpenPipe(io.StringIO):
            def read(self, *a):
                raise AssertionError("stdin must not be read")
        environ = {k: v for k, v in os.environ.items() if not k.startswith(("SOULS_", "SOULSHOUSE_"))}
        environ.update(self.env)
        pipe = OpenPipe()
        pipe.isatty = lambda: False
        with mock.patch.dict(os.environ, environ, clear=True), mock.patch.object(sys, "stdin", pipe), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = souls.main(["post", "c1", "--attach", path])
        self.assertEqual(code, 0)
        self.assertNotIn(b'name="content"', self.last()["body"])


class ResidentWatchTest(CliTestCase):
    """Resident keys poll the transcript. A reply is printed once, finished."""

    def setUp(self):
        super().setUp()
        self.house.route("GET", "/api/v1/conversations/c1/changes", status=403, body={"error": "person only"})
        self.script = []
        self.reads = []

        def show(req):
            self.reads.append(req["query"])
            rows = self.script.pop(0) if len(self.script) > 1 else self.script[0]
            after = dict(p.split("=", 1) for p in req["query"].split("&") if "=" in p).get("after_message_id")
            if after:
                ids = [r["id"] for r in rows]
                rows = rows[ids.index(after) + 1:] if after in ids else rows
            return 200, {"conversation": {"transcript": rows}}, {}
        self.house.routes[("GET", "/api/v1/conversations/c1")] = show

    def watch(self, *extra):
        code, out, err = self.run_cli("watch", "c1", "--interval", "0", "--json", *extra)
        return code, [json.loads(line) for line in out.splitlines()], err

    def test_an_unfinished_reply_is_waited_for_and_printed_once_complete(self):
        old = {"id": "m1", "content": "old", "completed": True}
        self.script = [
            [old],                                                        # startup
            [old, {"id": "m2", "content": "part", "completed": False}],   # arrives unfinished
            [old, {"id": "m2", "content": "partial th", "completed": False}],
            [old, {"id": "m2", "content": "partial thought, done", "completed": True},
             {"id": "m3", "content": "next", "completed": True}],
        ]
        code, printed, _ = self.watch("--once")
        self.assertEqual(code, 0)
        self.assertEqual([(m["id"], m["content"]) for m in printed],
                         [("m2", "partial thought, done"), ("m3", "next")])
        # The cursor never moved past the unfinished row while it was unfinished.
        self.assertTrue(all("after_message_id=m2" not in q for q in self.reads[:4]))

    def test_a_reply_in_flight_at_startup_is_delivered_when_it_finishes(self):
        self.script = [
            [{"id": "m1", "content": "q", "completed": True},
             {"id": "m2", "content": "wri", "completed": False},
             {"id": "m3", "content": "already there", "completed": True}],
            [{"id": "m1", "content": "q", "completed": True},
             {"id": "m2", "content": "written in full", "completed": True},
             {"id": "m3", "content": "already there", "completed": True}],
        ]
        code, printed, _ = self.watch("--once")
        self.assertEqual(code, 0)
        self.assertEqual([(m["id"], m["content"]) for m in printed], [("m2", "written in full")])

    def test_once_with_only_unfinished_rows_times_out_with_exit_8(self):
        self.script = [[{"id": "m1", "content": "q", "completed": True}],
                       [{"id": "m1", "content": "q", "completed": True},
                        {"id": "m2", "content": "never ends", "completed": False}]]
        code, printed, err = self.watch("--once", "--timeout", "0.3")
        self.assertEqual(code, souls.EXIT_TIMEOUT)
        self.assertEqual(printed, [])


if __name__ == "__main__":
    unittest.main()
