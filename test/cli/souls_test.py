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
                self.send_response(status)
                for k, v in headers.items():
                    self.send_header(k, v)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = _handle

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()

    def route(self, method, path, status=200, body=None, headers=None):
        self.routes[(method, path)] = (status, {} if body is None else body, headers or {})

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


if __name__ == "__main__":
    unittest.main()
