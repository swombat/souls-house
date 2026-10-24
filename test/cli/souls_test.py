"""Contract tests for public/cli/souls, against a local fake house.

Run: python3 -m unittest discover -s test/cli -p '*_test.py'
"""

import contextlib
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
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
        connect = socket.create_connection

        def local_connection(address, *args, **kwargs):
            if address[0] not in ("127.0.0.1", "::1", "localhost"):
                raise AssertionError("CLI contract tests may only connect to loopback")
            return connect(address, *args, **kwargs)

        guard = mock.patch("socket.create_connection", side_effect=local_connection)
        guard.start()
        self.addCleanup(guard.stop)
        self.house = FakeHouse()
        self.addCleanup(self.house.close)
        self.config_dir = tempfile.mkdtemp()
        self.env = {"XDG_CONFIG_HOME": self.config_dir, "SOULS_TOKEN": "hx_test", "SOULS_URL": self.house.url}

    def run_cli(self, *argv, stdin="", env=None, tty=False):
        environ = {k: v for k, v in os.environ.items()
                   if not k.startswith(("SOULS_", "SOULSHOUSE_", "HELIXKIT_"))}
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


class WhoTest(CliTestCase):
    def test_who_lists_the_account_with_reasons(self):
        self.house.route("GET", "/api/v1/who", body={
            "account": {"id": "a1", "name": "Nexus"},
            "people": [{"name": "Daniel", "kind": "person", "role": "owner",
                        "reads": "every conversation in this account", "site_admin": True}],
            "residents": [{"id": "r1", "name": "Claude", "kind": "resident",
                           "reads": "only the conversations it has a seat in", "seats": 12, "paused": False}],
            "site_admins": [],
            "not_covered": "Telegram conversations are separate."})
        code, out, _ = self.run_cli("who", "--account", "a1")
        self.assertEqual(code, 0)
        self.assertIn("account_id=a1", self.house.requests[-1]["query"])
        self.assertIn("- Daniel (owner): every conversation in this account · site admin", out)
        self.assertIn("- Claude (resident): only the conversations it has a seat in (12 seats)", out)
        self.assertIn("Telegram", out)

    def test_who_for_one_conversation_and_json(self):
        body = {"conversation": {"id": "c1", "title": "Build"}, "account": {"name": "Nexus"},
                "readers": [{"name": "Mira", "kind": "resident", "why": "seat in this conversation",
                             "closed_for_initiation": True}]}
        self.house.route("GET", "/api/v1/conversations/c1/who", body=body)
        code, out, _ = self.run_cli("who", "c1")
        self.assertEqual(code, 0)
        self.assertIn("# Who can read Build (c1) in Nexus", out)
        self.assertIn("- Mira (resident): seat in this conversation · won't start conversations here", out)
        code, out, _ = self.run_cli("who", "c1", "--json")
        self.assertEqual(json.loads(out), body)


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


class FieldTest(CliTestCase):
    def test_upload_sends_the_file_with_its_date_and_tags(self):
        self.house.route("POST", "/api/v1/field/files", status=201, body={"file": {"id": "f1"}})
        path = os.path.join(self.config_dir, "call.txt")
        with open(path, "w") as fh:
            fh.write("Anna: hello")
        code, out, _ = self.run_cli("field", "upload", path, "--title", "Call", "--date", "2019-03-14",
                                    "--tag", "archive", "--tag", "calls")
        self.assertEqual(code, 0)
        body = self.last()["body"]
        self.assertIn(b'name="file"; filename="call.txt"', body)
        self.assertIn(b'name="dated_at"\r\n\r\n2019-03-14', body)
        self.assertIn(b'name="title"\r\n\r\nCall', body)
        self.assertEqual(body.count(b'name="tags[]"'), 2)
        self.assertEqual(json.loads(out)["file"]["id"], "f1")

    def test_upload_without_a_date_sends_none(self):
        self.house.route("POST", "/api/v1/field/files", status=201, body={"file": {"id": "f1"}})
        path = os.path.join(self.config_dir, "a.md")
        with open(path, "w") as fh:
            fh.write("x")
        self.run_cli("field", "upload", path)
        self.assertNotIn(b"dated_at", self.last()["body"])

    def test_upload_of_a_missing_file_is_a_usage_error(self):
        code, _, err = self.run_cli("field", "upload", "/nonexistent/x.md")
        self.assertEqual(code, souls.EXIT_USAGE)
        self.assertIn("no such file", err)
        self.assertEqual(self.house.requests, [])

    def test_note_from_a_file_with_a_date(self):
        self.house.route("POST", "/api/v1/whiteboards", status=201, body={"whiteboard": {"id": "w1"}})
        path = os.path.join(self.config_dir, "diary.md")
        with open(path, "w") as fh:
            fh.write("# May\nIt rained.")
        code, _, _ = self.run_cli("field", "note", "Diary, May 2018", "--file", path, "--date", "2018-05-01",
                                  "--summary", "Rain")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(self.last()["body"]), {
            "name": "Diary, May 2018", "content": "# May\nIt rained.", "summary": "Rain", "dated_at": "2018-05-01"})

    def test_note_from_an_argument_without_a_date(self):
        self.house.route("POST", "/api/v1/whiteboards", status=201, body={"whiteboard": {"id": "w1"}})
        self.run_cli("field", "note", "Plan", "Buy milk")
        self.assertEqual(json.loads(self.last()["body"]), {"name": "Plan", "content": "Buy milk"})

    def test_a_note_file_that_is_not_utf8_is_a_usage_error(self):
        path = os.path.join(self.config_dir, "utf16.md")
        with open(path, "w", encoding="utf-16") as fh:
            fh.write("It rained.")
        code, _, err = self.run_cli("field", "note", "Diary", "--file", path)
        self.assertEqual(code, souls.EXIT_USAGE)
        self.assertIn("is not UTF-8 text", err)
        self.assertNotIn("Traceback", err)
        self.assertEqual(self.house.requests, [])

    def test_date_redates_a_recording_or_file(self):
        for kind, path, param in (("recording", "/api/v1/field/recordings/r1", "recorded_at"),
                                  ("file", "/api/v1/field/files/r1", "dated_at")):
            self.house.route("PATCH", path, body={"ok": True})
            code, _, _ = self.run_cli("field", "date", kind, "r1", "2019-03-14")
            self.assertEqual(code, 0, kind)
            req = self.last()
            self.assertEqual((req["method"], req["path"]), ("PATCH", path))
            self.assertEqual(json.loads(req["body"]), {param: "2019-03-14"})

    def test_date_on_a_note_sends_the_lock_version_it_read(self):
        self.house.route("GET", "/api/v1/whiteboards/w1", body={"whiteboard": {"id": "w1", "lock_version": 4}})
        self.house.route("PATCH", "/api/v1/whiteboards/w1", body={"whiteboard": {"id": "w1"}})
        code, _, _ = self.run_cli("field", "date", "note", "w1", "2018-05-01")
        self.assertEqual(code, 0)
        self.assertEqual([r["method"] for r in self.house.requests], ["GET", "PATCH"])
        self.assertEqual(json.loads(self.last()["body"]), {"dated_at": "2018-05-01", "lock_version": 4})

    def test_date_clear_sends_an_empty_date(self):
        self.house.route("PATCH", "/api/v1/field/recordings/r1", body={"ok": True})
        self.run_cli("field", "date", "recording", "r1", "--clear")
        self.assertEqual(json.loads(self.last()["body"]), {"recorded_at": ""})

    def test_date_needs_exactly_one_of_a_date_or_clear(self):
        for argv in (("field", "date", "recording", "r1"), ("field", "date", "recording", "r1", "2019-03-14", "--clear")):
            code, _, err = self.run_cli(*argv)
            self.assertEqual(code, souls.EXIT_USAGE, argv)
            self.assertIn("--clear", err)
        self.assertEqual(self.house.requests, [])

    def test_field_without_a_subcommand_prints_help(self):
        code, out, _ = self.run_cli("field")
        self.assertEqual(code, souls.EXIT_USAGE)
        self.assertIn("upload|note|date", out)
        self.assertEqual(self.house.requests, [])

    LINES = {"id": "KJkAjl", "revision": "rev1",
             "lines": [{"line": 1, "speaker": "Sanda", "text": "Cinquante kilos."},
                       {"line": 2, "speaker": None, "text": "[laughter]"}]}

    def test_lines_prints_numbered_lines_and_the_revision(self):
        self.house.route("GET", "/api/v1/field/recordings/KJkAjl/lines", body=self.LINES)
        code, out, _ = self.run_cli("field", "lines", "KJkAjl")
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), ["revision rev1", "   1  Sanda: Cinquante kilos.", "   2  [laughter]"])

    def test_correct_reads_the_line_then_sends_it_with_was_and_revision(self):
        self.house.route("GET", "/api/v1/field/recordings/KJkAjl/lines", body=self.LINES)
        self.house.route("PATCH", "/api/v1/field/recordings/KJkAjl/lines/1", body={
            "revision": "rev2", "lines": self.LINES["lines"],
            "line": {"line": 1, "speaker": "Sanda", "text": "Soixante-dix kilos."}})
        code, out, _ = self.run_cli("field", "correct", "KJkAjl", "1", "Soixante-dix kilos.")
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), ["revision rev2", "   1  Sanda: Soixante-dix kilos."],
                         "only the corrected line, not the whole transcript")
        self.assertEqual(json.loads(self.last()["body"]),
                         {"text": "Soixante-dix kilos.", "was": "Cinquante kilos.", "revision": "rev1"})

    def test_correct_with_was_and_revision_sends_them_without_reading(self):
        self.house.route("PATCH", "/api/v1/field/recordings/KJkAjl/lines/1", status=409,
                         body={"error": "The transcript has changed", "revision": "rev2"})
        code, _, err = self.run_cli("field", "correct", "KJkAjl", "1", "-", "--was", "Cinquante kilos.",
                                    "--revision", "rev1", stdin="Soixante-dix kilos.\n")
        self.assertEqual(code, souls.EXIT_CONFLICT)
        self.assertIn("The transcript has changed", err)
        self.assertEqual(len(self.house.requests), 1)
        self.assertEqual(json.loads(self.last()["body"])["text"], "Soixante-dix kilos.")

    def test_correcting_a_line_that_does_not_exist_is_a_usage_error_without_a_write(self):
        self.house.route("GET", "/api/v1/field/recordings/KJkAjl/lines", body=self.LINES)
        code, _, err = self.run_cli("field", "correct", "KJkAjl", "9", "x")
        self.assertEqual(code, souls.EXIT_USAGE)
        self.assertIn("has no line 9 (it has 2)", err)
        self.assertEqual([r["method"] for r in self.house.requests], ["GET"])

    SPEAKER_LINES = {"id": "KJkAjl", "revision": "rev1",
                     "lines": [{"line": 1, "speaker": "Sanda", "speaker_id": "spA", "text": "Cinquante kilos."},
                               {"line": 2, "speaker": "Ioan", "speaker_id": "spB", "text": "Non, soixante-dix."},
                               {"line": 3, "speaker": None, "speaker_id": None, "text": "[laughter]"}]}

    def test_speaker_by_name_sends_the_id_with_was_and_revision(self):
        self.house.route("GET", "/api/v1/field/recordings/KJkAjl/lines", body=self.SPEAKER_LINES)
        self.house.route("PATCH", "/api/v1/field/recordings/KJkAjl/lines/2", body={
            "revision": "rev2", "lines": [],
            "line": {"line": 2, "speaker": "Sanda", "speaker_id": "spA", "text": "Non, soixante-dix."}})
        code, out, _ = self.run_cli("field", "speaker", "KJkAjl", "2", "sanda")
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), ["revision rev2", "   2  Sanda: Non, soixante-dix."])
        self.assertEqual(json.loads(self.last()["body"]),
                         {"speaker": "spA", "was": "Non, soixante-dix.", "revision": "rev1"})

    def test_speaker_accepts_an_id_or_new(self):
        for who, sent in (("spB", "spB"), ("New", "new")):
            self.house.requests.clear()
            self.house.route("GET", "/api/v1/field/recordings/KJkAjl/lines", body=self.SPEAKER_LINES)
            self.house.route("PATCH", "/api/v1/field/recordings/KJkAjl/lines/1", body={
                "revision": "rev2", "lines": [], "line": {"line": 1, "speaker": "Speaker 3", "text": "Cinquante kilos."}})
            code, _, _ = self.run_cli("field", "speaker", "KJkAjl", "1", who, "--revision", "rev1")
            self.assertEqual(code, 0, who)
            self.assertEqual(json.loads(self.last()["body"]),
                             {"speaker": sent, "was": "Cinquante kilos.", "revision": "rev1"}, who)

    def test_speaker_nobody_by_that_name_is_a_usage_error_naming_who_speaks(self):
        self.house.route("GET", "/api/v1/field/recordings/KJkAjl/lines", body=self.SPEAKER_LINES)
        code, _, err = self.run_cli("field", "speaker", "KJkAjl", "1", "Anna")
        self.assertEqual(code, souls.EXIT_USAGE)
        self.assertIn("Ioan, Sanda, or 'new'", err)
        self.assertEqual([r["method"] for r in self.house.requests], ["GET"])

    def test_speaker_stale_revision_is_a_conflict_without_a_write(self):
        # Even when the line it names has since merged away.
        self.house.route("GET", "/api/v1/field/recordings/KJkAjl/lines", body=self.SPEAKER_LINES)
        for line in ("1", "9"):
            code, _, err = self.run_cli("field", "speaker", "KJkAjl", line, "Ioan", "--revision", "rev0")
            self.assertEqual(code, souls.EXIT_CONFLICT, line)
            self.assertIn("has changed since revision rev0", err)
        self.assertEqual({r["method"] for r in self.house.requests}, {"GET"})

    def test_speaker_server_conflict_is_a_conflict(self):
        self.house.route("GET", "/api/v1/field/recordings/KJkAjl/lines", body=self.SPEAKER_LINES)
        self.house.route("PATCH", "/api/v1/field/recordings/KJkAjl/lines/1", status=409,
                         body={"error": "The transcript has changed", "revision": "rev2"})
        code, _, err = self.run_cli("field", "speaker", "KJkAjl", "1", "Ioan")
        self.assertEqual(code, souls.EXIT_CONFLICT)
        self.assertIn("The transcript has changed", err)

    def test_speaker_a_name_two_speakers_share_is_refused_listing_their_ids(self):
        # A voice someone named "Speaker 2" and an unnamed second speaker read the
        # same; /lines can't say whether they are one person.
        lines = {"id": "KJkAjl", "revision": "rev1",
                 "lines": [{"line": 1, "speaker": "Speaker 2", "speaker_id": "named", "text": "One."},
                           {"line": 2, "speaker": "Speaker 2", "speaker_id": "unnamed", "text": "Two."},
                           {"line": 3, "speaker": "Other", "speaker_id": "other", "text": "Three."}]}
        self.house.route("GET", "/api/v1/field/recordings/KJkAjl/lines", body=lines)
        code, _, err = self.run_cli("field", "speaker", "KJkAjl", "3", "Speaker 2")
        self.assertEqual(code, souls.EXIT_USAGE)
        self.assertIn("named (lines 1); unnamed (lines 2)", err)
        self.assertEqual([r["method"] for r in self.house.requests], ["GET"])
        self.house.route("PATCH", "/api/v1/field/recordings/KJkAjl/lines/3", body={
            "revision": "rev2", "lines": [], "line": {"line": 3, "speaker": "Speaker 2", "text": "Three."}})
        code, _, _ = self.run_cli("field", "speaker", "KJkAjl", "3", "unnamed")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(self.last()["body"])["speaker"], "unnamed")

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
        environ = {k: v for k, v in os.environ.items() if not k.startswith(("SOULS_", "SOULSHOUSE_", "HELIXKIT_"))}
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


class GlossaryTest(CliTestCase):
    def test_list_prints_pinned_and_source_one_per_line(self):
        self.house.route("GET", "/api/v1/transcription_glossary", body={
            "account_id": "a1", "keyterm_limit": 100,
            "terms": [
                {"id": None, "term": "souls.house", "source": "built_in", "pinned": False, "built_in": True},
                {"id": "t1", "term": "Lume", "source": "manual", "pinned": True, "built_in": False,
                 "sightings_count": 0, "last_seen_at": None, "created_at": "2026-10-01T00:00:00Z", "created_by": "Daniel"},
            ],
            "removed": [],
        })
        code, out, _ = self.run_cli("glossary")
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), ["souls.house  [built in]", "Lume  [added, pinned]"])
        self.assertEqual(self.last()["method"], "GET")
        self.assertEqual(self.last()["path"], "/api/v1/transcription_glossary")

    def test_list_is_the_same_as_bare_glossary(self):
        self.house.route("GET", "/api/v1/transcription_glossary",
                          body={"terms": [{"term": "x", "source": "manual", "pinned": False}], "removed": []})
        code1, out1, _ = self.run_cli("glossary")
        code2, out2, _ = self.run_cli("glossary", "list")
        self.assertEqual((code1, out1), (code2, out2))

    def test_list_removed_lists_the_tombstones_not_the_active_terms(self):
        self.house.route("GET", "/api/v1/transcription_glossary", body={
            "terms": [{"term": "active", "source": "manual", "pinned": False}],
            "removed": [{"id": "t2", "term": "gone", "source": "harvested", "pinned": False,
                         "removed_at": "2026-09-01T12:00:00Z"}],
        })
        code, out, _ = self.run_cli("glossary", "--removed")
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), ["gone  [harvested, removed 2026-09-01T12:00]"])

    def test_list_json_prints_the_raw_response_account_scoped(self):
        self.house.route("GET", "/api/v1/transcription_glossary", body={"terms": [], "removed": [], "keyterm_limit": 100})
        code, out, _ = self.run_cli("--account", "A1", "glossary", "--json")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out), {"terms": [], "removed": [], "keyterm_limit": 100})
        self.assertIn("account_id=A1", self.last()["query"])

    def test_add_sends_term_and_pin_as_a_json_body(self):
        self.house.route("POST", "/api/v1/transcription_glossary", status=201, body={"term": {"id": "t9", "term": "widget"}})
        code, out, _ = self.run_cli("glossary", "add", "widget", "--pin")
        self.assertEqual(code, 0)
        req = self.last()
        self.assertEqual(req["method"], "POST")
        self.assertEqual(req["path"], "/api/v1/transcription_glossary")
        self.assertEqual(json.loads(req["body"]), {"term": "widget", "pinned": True})
        self.assertEqual(json.loads(out)["term"]["id"], "t9")

    def test_add_without_pin_sends_pinned_false(self):
        self.house.route("POST", "/api/v1/transcription_glossary", status=201, body={"term": {"id": "t9"}})
        self.run_cli("glossary", "add", "widget")
        self.assertEqual(json.loads(self.last()["body"]), {"term": "widget", "pinned": False})

    def test_add_takes_several_terms_one_request_each(self):
        self.house.route("POST", "/api/v1/transcription_glossary", status=201, body={"term": {"id": "t9"}})
        code, _, _ = self.run_cli("glossary", "add", "alpha", "beta two", "--pin")
        self.assertEqual(code, 0)
        bodies = [json.loads(r["body"]) for r in self.house.requests]
        self.assertEqual(bodies, [{"term": "alpha", "pinned": True}, {"term": "beta two", "pinned": True}])

    def test_add_with_no_terms_is_a_usage_error_without_a_request(self):
        code, _, err = self.run_cli("glossary", "add")
        self.assertEqual(code, souls.EXIT_USAGE)
        self.assertEqual(self.house.requests, [])
        self.assertIn("at least one TERM", err)

    def test_remove_sends_term_as_a_json_body_on_delete(self):
        self.house.route("DELETE", "/api/v1/transcription_glossary", body={"removed": {"term": "widget", "removed_at": "now"}})
        code, out, _ = self.run_cli("glossary", "remove", "widget")
        self.assertEqual(code, 0)
        req = self.last()
        self.assertEqual(req["method"], "DELETE")
        self.assertEqual(req["path"], "/api/v1/transcription_glossary")
        self.assertEqual(json.loads(req["body"]), {"term": "widget"})
        self.assertEqual(json.loads(out)["removed"]["term"], "widget")

    def test_pin_sends_pinned_true(self):
        self.house.route("PATCH", "/api/v1/transcription_glossary", body={"term": {"term": "widget", "pinned": True}})
        code, out, _ = self.run_cli("glossary", "pin", "widget")
        self.assertEqual(code, 0)
        req = self.last()
        self.assertEqual(req["method"], "PATCH")
        self.assertEqual(json.loads(req["body"]), {"term": "widget", "pinned": True})
        self.assertTrue(json.loads(out)["term"]["pinned"])

    def test_unpin_sends_pinned_false(self):
        self.house.route("PATCH", "/api/v1/transcription_glossary", body={"term": {"term": "widget", "pinned": False}})
        code, _, _ = self.run_cli("glossary", "unpin", "widget")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(self.last()["body"]), {"term": "widget", "pinned": False})

    def test_pin_with_more_than_one_term_is_a_usage_error_without_a_request(self):
        code, _, err = self.run_cli("glossary", "pin", "widget", "gadget")
        self.assertEqual(code, souls.EXIT_USAGE)
        self.assertEqual(self.house.requests, [])
        self.assertIn("exactly one TERM", err)


class IntegrationsTest(CliTestCase):
    """souls integrations list|providers|connect|grant|disconnect."""

    PROVIDERS = {"providers": [
        {"key": "porkbun", "name": "Porkbun", "management_scopes": ["personal", "account_managed"],
         "credential_fields": [{"key": "api_key", "label": "API key", "type": "password"},
                               {"key": "secret_key", "label": "Secret API key", "type": "password"}]},
        {"key": "pipedrive", "name": "Pipedrive CRM", "management_scopes": ["personal"],
         "credential_fields": [{"key": "company_domain", "label": "Company domain", "type": "text"},
                               {"key": "api_token", "label": "Personal API token", "type": "password"}]},
    ]}

    def setUp(self):
        super().setUp()
        self.house.route("GET", "/api/v1/account/service_connections/providers", body=self.PROVIDERS)
        self.house.route("POST", "/api/v1/account/service_connections", status=201,
                         body={"service_connection": {"id": "svc_9", "provider": "porkbun", "label": "Porkbun (acme)"}})

    def posted(self):
        return [json.loads(r["body"]) for r in self.house.requests
                if (r["method"], r["path"]) == ("POST", "/api/v1/account/service_connections")]

    def test_bare_and_list_read_the_account_connections(self):
        self.house.route("GET", "/api/v1/account/service_connections", body={"service_connections": []})
        for argv in (("integrations",), ("integrations", "list")):
            code, _, _ = self.run_cli(*argv)
            self.assertEqual(code, 0)
            self.assertEqual((self.last()["method"], self.last()["path"]), ("GET", "/api/v1/account/service_connections"))

    def test_connect_reads_secrets_as_json_on_stdin(self):
        code, out, _ = self.run_cli("integrations", "connect", "porkbun", "--json", "-",
                                    stdin='{"api_key": "pk1_a", "secret_key": "sk1_b"}')
        self.assertEqual(code, 0)
        self.assertEqual(self.posted(), [{"provider": "porkbun", "management_scope": "personal",
                                          "credentials": {"api_key": "pk1_a", "secret_key": "sk1_b"}}])
        self.assertEqual(json.loads(out)["service_connection"]["id"], "svc_9")

    def test_connect_prompts_for_missing_secrets_without_echo_in_a_terminal(self):
        with mock.patch("getpass.getpass", side_effect=["sk1_hidden"]) as hidden:
            code, _, _ = self.run_cli("integrations", "connect", "porkbun", "--field", "api_key=pk1_a", tty=True)
        self.assertEqual(code, 0)
        hidden.assert_called_once()
        self.assertEqual(self.posted()[0]["credentials"], {"api_key": "pk1_a", "secret_key": "sk1_hidden"})

    def test_connect_without_a_terminal_names_what_is_missing_and_sends_nothing(self):
        code, _, err = self.run_cli("integrations", "connect", "porkbun", "--field", "api_key=pk1_a")
        self.assertEqual(code, souls.EXIT_USAGE)
        self.assertIn("missing secret_key", err)
        self.assertEqual(self.posted(), [])

    def test_connect_refuses_unknown_fields_and_unknown_providers_before_posting(self):
        code, _, err = self.run_cli("integrations", "connect", "porkbun", "--field", "password=x", "--field", "api_key=a",
                                    "--field", "secret_key=b")
        self.assertEqual(code, souls.EXIT_USAGE)
        self.assertIn("its fields are: api_key, secret_key", err)
        self.assertNotIn("password", err)
        code, _, err = self.run_cli("integrations", "connect", "dropbox", "--json", "{}")
        self.assertEqual(code, souls.EXIT_USAGE)
        self.assertIn("can: porkbun, pipedrive", err)
        self.assertEqual(self.posted(), [])

    def test_connect_passes_scope_label_and_grants_each_resident(self):
        self.house.route("PATCH", "/api/v1/residents/r1/service_accesses/svc_9",
                         body={"service_connection": {"id": "svc_9", "enabled": True}})
        code, out, _ = self.run_cli("integrations", "connect", "porkbun", "--scope", "account_managed", "--label", "DNS",
                                    "--grant", "r1", "--json", '{"api_key": "a", "secret_key": "b"}')
        self.assertEqual(code, 0)
        body = self.posted()[0]
        self.assertEqual((body["management_scope"], body["label"]), ("account_managed", "DNS"))
        self.assertEqual(json.loads(self.last()["body"]), {"enabled": True})
        self.assertEqual(json.loads(out)["granted"], [{"resident_id": "r1", "enabled": True}])

    def test_rejected_credential_input_never_echoes_what_was_typed(self):
        secret = "sk1_SYNTHETIC_SECRET_9f3a"
        for argv, stdin in (
            (("integrations", "connect", "porkbun", "--field", secret), ""),
            (("integrations", "connect", "porkbun", "--json", "-"), '{"%s": "x", "api_key": "a", "secret_key": "b"}' % secret),
            (("integrations", "connect", "porkbun", "--json", "-"), '{"api_key": "a", "secret_key": "b", "oops": "%s"}' % secret),
        ):
            code, out, err = self.run_cli(*argv, stdin=stdin)
            self.assertEqual(code, souls.EXIT_USAGE)
            self.assertNotIn(secret, out + err)
        self.assertEqual(self.posted(), [])

    def test_grant_and_revoke_patch_the_resident_access(self):
        self.house.route("PATCH", "/api/v1/residents/r1/service_accesses/svc_9",
                         body={"service_connection": {"id": "svc_9"}})
        self.run_cli("integrations", "grant", "svc_9", "--resident", "r1")
        self.assertEqual(json.loads(self.last()["body"]), {"enabled": True})
        self.run_cli("integrations", "grant", "svc_9", "--resident", "r1", "--revoke")
        self.assertEqual(json.loads(self.last()["body"]), {"enabled": False})

    def test_disconnect_deletes_the_connection(self):
        self.house.route("DELETE", "/api/v1/account/service_connections/svc_9", body={"disconnected": {"id": "svc_9"}})
        code, _, _ = self.run_cli("integrations", "disconnect", "svc_9")
        self.assertEqual(code, 0)
        self.assertEqual((self.last()["method"], self.last()["path"]), ("DELETE", "/api/v1/account/service_connections/svc_9"))


class VoiceSamplesTest(CliTestCase):
    """Only local fake HTTP servers and synthetic credentials."""

    def audio(self, name="clip.wav", data=b"RIFF prepared clip"):
        path = os.path.join(self.config_dir, name)
        with open(path, "wb") as target:
            target.write(data)
        return path

    def upload_args(self, *extra):
        return ("field", "samples", "upload", "v1", self.audio(),
                "--source-identifier", "archive/call#1", "--source-session", "canonical/call",
                "--idempotency-key", "fixed-retry-key", *extra)

    def test_voices_list_create_rename_delete_and_bare_list(self):
        for method, path, argv, payload in (
            ("GET", "/api/v1/field/voices", ("list",), None),
            ("GET", "/api/v1/field/voices", (), None),
            ("POST", "/api/v1/field/voices", ("create", "A name"), {"name": "A name"}),
            ("PATCH", "/api/v1/field/voices/v1", ("rename", "v1", "New name"), {"name": "New name"}),
            ("DELETE", "/api/v1/field/voices/v1", ("delete", "v1"), None),
        ):
            with self.subTest(argv=argv):
                self.house.route(method, path, body={"ok": True})
                code, out, err = self.run_cli("field", "voices", *argv)
                self.assertEqual((code, err), (0, ""))
                self.assertEqual(json.loads(out), {"ok": True})
                self.assertEqual((self.last()["method"], self.last()["path"]), (method, path))
                self.assertEqual(json.loads(self.last()["body"]) if payload else None, payload)

    def test_resolve_sends_literal_name_as_query_without_creating(self):
        self.house.route("GET", "/api/v1/field/voices/resolve", status=404, body={"error": "No exact match"})
        name = "  Zoë & /?+#  "
        code, out, err = self.run_cli("field", "voices", "resolve", name)
        self.assertEqual(code, souls.EXIT_NOT_FOUND)
        self.assertEqual(out, "")
        self.assertEqual(json.loads(err)["status"], 404)
        self.assertEqual(urllib.parse.parse_qs(self.last()["query"]), {"name": [name]})
        self.assertEqual([r["method"] for r in self.house.requests], ["GET"])

    def test_public_ids_are_url_encoded_without_assuming_the_sample_kind(self):
        opaque = "standalone/é ?#%"
        path = "/api/v1/field/samples/" + urllib.parse.quote(opaque, safe="")
        self.house.route("GET", path, body={"sample": {"id": opaque}})
        code, out, _ = self.run_cli("field", "samples", "inspect", opaque)
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["sample"]["id"], opaque)
        self.assertEqual(self.last()["path"], path)
        self.assertEqual(self.last()["query"], "")

    def test_list_is_voice_scoped_and_account_option_reaches_leaf(self):
        self.house.route("GET", "/api/v1/field/voices/v1/samples", body={"samples": []})
        code, out, _ = self.run_cli("field", "samples", "list", "v1", "--account", "a /+")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out), {"samples": []})
        self.assertEqual(urllib.parse.parse_qs(self.last()["query"]), {"account_id": ["a /+"]})

    def test_upload_hashes_only_explicit_original_file_and_preserves_metadata(self):
        original = b"original uncut recording, NOT clip bytes"
        source = self.audio("original.wav", original)
        self.house.route("POST", "/api/v1/field/voices/v1/samples", status=201, body={"sample": {"id": "s1"}})
        code, out, err = self.run_cli(*self.upload_args(
            "--source-file", source, "--start-ms", "0", "--end-ms", "2300",
            "--recorded-at", "2020-02-03", "--recording-id", "r1"))
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(json.loads(out)["sample"]["id"], "s1")
        req = self.last()
        self.assertEqual(req["headers"]["authorization"], "Bearer hx_test")
        self.assertTrue(req["headers"]["content-type"].startswith("multipart/form-data; boundary="))
        body = req["body"]
        self.assertIn(b'name="audio"; filename="clip.wav"', body)
        self.assertIn(b"RIFF prepared clip", body)
        self.assertNotIn(original, body)
        for name, value in (
            ("source_identifier", "archive/call#1"), ("source_session", "canonical/call"),
            ("source_sha256", hashlib.sha256(original).hexdigest()), ("idempotency_key", "fixed-retry-key"),
            ("start_ms", "0"), ("end_ms", "2300"), ("recorded_at", "2020-02-03"), ("recording_id", "r1"),
        ):
            self.assertIn(f'name="{name}"\r\n\r\n{value}\r\n'.encode(), body)

    def test_retry_keeps_the_supplied_idempotency_key_and_hash(self):
        attempts = []

        def upload(req):
            attempts.append(req)
            return (503, {"error": "retry later"}, {}) if len(attempts) == 1 else (200, {"sample": {"id": "s1"}}, {})
        self.house.routes[("POST", "/api/v1/field/voices/v1/samples")] = upload
        argv = self.upload_args("--source-sha256", "A" * 64)
        self.assertEqual(self.run_cli(*argv)[0], souls.EXIT_ERROR)
        self.assertEqual(len(attempts), 1, "no hidden automatic retry")
        self.assertEqual(self.run_cli(*argv)[0], 0)
        for req in attempts:
            self.assertIn(b'name="idempotency_key"\r\n\r\nfixed-retry-key\r\n', req["body"])
            self.assertIn(b'name="source_sha256"\r\n\r\n' + b"a" * 64 + b"\r\n", req["body"])
            self.assertNotIn(b'name="start_ms"', req["body"])
            self.assertNotIn(b'name="recorded_at"', req["body"])

    def test_upload_refuses_missing_hash_invalid_ranges_and_source_hash_mismatch(self):
        source = self.audio("original.wav", b"original")
        for extra in (
            (), ("--source-sha256", "bad"), ("--source-sha256", "0" * 64, "--start-ms", "1"),
            ("--source-sha256", "0" * 64, "--start-ms", "5", "--end-ms", "5"),
            ("--source-sha256", "0" * 64, "--start-ms", "-1", "--end-ms", "5"),
            ("--source-sha256", "0" * 64, "--source-file", source),
            ("--source-file", "/nonexistent/original.wav"),
        ):
            with self.subTest(extra=extra):
                code, out, err = self.run_cli(*self.upload_args(*extra))
                self.assertEqual(code, souls.EXIT_USAGE)
                self.assertEqual(out, "")
                self.assertEqual(json.loads(err)["exit_code"], souls.EXIT_USAGE)
        self.assertEqual(self.house.requests, [])

    def test_upload_prints_server_deduplication_receipt_unchanged(self):
        for reason in ("retry", "identical", "overlap"):
            receipt = {"sample": {"id": "existing", "content_sha256": "b" * 64}, "deduplicated": reason}
            self.house.route("POST", "/api/v1/field/voices/v1/samples", status=200, body=receipt)
            code, out, err = self.run_cli(*self.upload_args("--source-sha256", "a" * 64))
            self.assertEqual((code, err), (0, ""))
            self.assertEqual(json.loads(out), receipt)

    def test_accept_requires_listening_and_does_not_claim_confirmation(self):
        code, out, err = self.run_cli("field", "samples", "accept", "s1", "--digest", "digest")
        self.assertEqual(code, souls.EXIT_USAGE)
        self.assertIn("--listened", json.loads(err)["error"])
        self.assertEqual(self.house.requests, [])
        self.house.route("PATCH", "/api/v1/field/samples/s1", status=403, body={"error": "OAuth human required"})
        code, out, err = self.run_cli("field", "samples", "accept", "s1", "--digest", "digest", "--listened")
        self.assertEqual(code, souls.EXIT_AUTH)
        self.assertEqual(out, "")
        self.assertIn("OAuth", json.loads(err)["error"])
        self.assertIn("does not upgrade", json.loads(err)["error"])
        self.assertEqual(json.loads(self.last()["body"]), {"included": True, "digest": "digest"})
        self.assertNotIn("confirmed_by", self.last()["body"].decode())

    def test_reject_correct_delete_use_only_the_requested_operation(self):
        for action, options, method, payload in (
            ("reject", ("--digest", "d1"), "PATCH", {"included": False, "digest": "d1"}),
            ("correct", ("--voice", "another-opaque-id", "--digest", "d1"), "PATCH",
             {"voice_id": "another-opaque-id", "digest": "d1"}),
            ("delete", ("--digest", "d1"), "DELETE", {"digest": "d1"}),
        ):
            self.house.route(method, "/api/v1/field/samples/s1", body={"ok": True})
            code, out, _ = self.run_cli("field", "samples", action, "s1", *options)
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(out), {"ok": True})
            self.assertEqual(json.loads(self.last()["body"]) if payload else None, payload)

    def test_download_writes_binary_and_outputs_json_receipt(self):
        self.house.route("GET", "/api/v1/field/samples/s1/audio", body=b"\x00audio\xff")
        target = os.path.join(self.config_dir, "download.wav")
        code, out, err = self.run_cli("field", "samples", "download", "s1", "--digest", "d /+#", "-o", target)
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(json.loads(out), {"output": target, "bytes": 7})
        with open(target, "rb") as audio:
            self.assertEqual(audio.read(), b"\x00audio\xff")
        self.assertEqual(urllib.parse.parse_qs(self.last()["query"]), {"digest": ["d /+#"]})

    def test_voice_requests_refuse_cross_origin_and_same_origin_redirects(self):
        other = FakeHouse()
        self.addCleanup(other.close)
        other.route("GET", "/stolen", body={"ok": True})
        self.house.route("GET", "/same", body={"ok": True})
        for location in (other.url + "/stolen", "/same"):
            for action, path, options in (
                ("inspect", "/api/v1/field/samples/s1", ()),
                ("download", "/api/v1/field/samples/s1/audio",
                 ("--digest", "d1", "-o", os.path.join(self.config_dir, "redirect.wav"))),
            ):
                self.house.route("GET", path, status=302, body=b"", headers={"Location": location})
                code, out, err = self.run_cli("field", "samples", action, "s1", *options)
                self.assertEqual(code, souls.EXIT_ERROR)
                self.assertEqual(out, "")
                self.assertEqual(json.loads(err)["status"], 302)
        self.assertEqual(other.requests, [])
        self.assertFalse(any(req["path"] == "/same" for req in self.house.requests))

    def test_api_errors_are_json_and_redact_the_bearer(self):
        for status, expected in ((401, souls.EXIT_AUTH), (403, souls.EXIT_AUTH), (404, souls.EXIT_NOT_FOUND),
                                 (409, souls.EXIT_CONFLICT), (422, souls.EXIT_INVALID), (500, souls.EXIT_ERROR)):
            self.house.route("GET", "/api/v1/field/voices", status=status, body={"error": "bad hx_test"})
            code, out, err = self.run_cli("field", "voices", "list")
            self.assertEqual(code, expected)
            self.assertEqual(out, "")
            self.assertNotIn("hx_test", err)
            self.assertEqual(json.loads(err)["status"], status)

    def test_legacy_environment_alias_is_isolated_and_supported(self):
        self.house.route("GET", "/api/v1/field/voices", body={"voices": []})
        env = {"XDG_CONFIG_HOME": self.config_dir, "HELIXKIT_BEARER_TOKEN": "hx_legacy_dummy",
               "HELIXKIT_APP_URL": self.house.url}
        code, _, _ = self.run_cli("field", "voices", "list", env=env)
        self.assertEqual(code, 0)
        self.assertEqual(self.last()["headers"]["authorization"], "Bearer hx_legacy_dummy")

    def test_missing_required_upload_option_is_json_usage_error(self):
        parser, _ = souls.build_parser()
        error = io.StringIO()
        with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(error):
            parser.parse_args(["field", "samples", "upload", "v1", self.audio()])
        self.assertEqual(raised.exception.code, souls.EXIT_USAGE)
        self.assertEqual(json.loads(error.getvalue())["exit_code"], souls.EXIT_USAGE)
        self.assertEqual(self.house.requests, [])

    def test_accept_with_human_app_token_only_sends_included_and_digest(self):
        self.house.route("PATCH", "/api/v1/field/samples/s1", body={"sample": {"included": True}})
        env = dict(self.env, SOULS_TOKEN="oauth_dummy_human")
        code, out, err = self.run_cli("field", "samples", "accept", "s1", "--digest", "d1",
                                    "--listened", env=env)
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(json.loads(out), {"sample": {"included": True}})
        self.assertEqual(self.last()["headers"]["authorization"], "Bearer oauth_dummy_human")
        self.assertEqual(json.loads(self.last()["body"]), {"included": True, "digest": "d1"})

    def test_api_key_can_reinclude_an_unchanged_already_confirmed_sample(self):
        self.house.route("PATCH", "/api/v1/field/samples/s1",
                         body={"sample": {"included": True, "confirmed_by": "original human"}})
        code, out, err = self.run_cli("field", "samples", "accept", "s1", "--digest", "d1", "--listened")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(json.loads(out)["sample"]["confirmed_by"], "original human")
        self.assertEqual(json.loads(self.last()["body"]), {"included": True, "digest": "d1"})

    def test_correct_and_delete_require_an_explicit_digest(self):
        parser, _ = souls.build_parser()
        for argv in (["correct", "s1", "--voice", "v2"], ["delete", "s1"]):
            error = io.StringIO()
            with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(error):
                parser.parse_args(["field", "samples", *argv])
            self.assertEqual(raised.exception.code, souls.EXIT_USAGE)
            self.assertIn("--digest", json.loads(error.getvalue())["error"])
        self.assertEqual(self.house.requests, [])

    def test_missing_credentials_and_invalid_json_have_stable_errors(self):
        code, _, err = self.run_cli("field", "voices", env={"XDG_CONFIG_HOME": self.config_dir})
        self.assertEqual(code, souls.EXIT_AUTH)
        self.assertEqual(json.loads(err)["status"], None)
        self.assertEqual(self.house.requests, [])
        self.house.route("GET", "/api/v1/field/voices", body=b"<not-json>")
        code, out, err = self.run_cli("field", "voices")
        self.assertEqual(code, souls.EXIT_ERROR)
        self.assertEqual(out, "")
        self.assertIn("expected JSON", json.loads(err)["error"])


class RepositoryWatchesTest(CliTestCase):
    """souls repos / souls watches add|list|show|cancel (repository watches)."""

    def test_repos_lists_connected_repositories(self):
        self.house.route("GET", "/api/v1/repositories",
                          body={"repositories": [{"id": "r1", "full_name": "acme/widgets", "hook_status": "installed"}]})
        code, out, _ = self.run_cli("repos")
        self.assertEqual(code, 0)
        self.assertEqual(self.last()["method"], "GET")
        self.assertEqual(json.loads(out)["repositories"][0]["full_name"], "acme/widgets")

    def test_repos_list_is_the_same_as_bare_repos(self):
        self.house.route("GET", "/api/v1/repositories", body={"repositories": []})
        code, _, _ = self.run_cli("repos", "list")
        self.assertEqual(code, 0)
        self.assertEqual((self.last()["method"], self.last()["path"]), ("GET", "/api/v1/repositories"))

    def test_repos_connect_posts_full_name_and_optional_connection(self):
        self.house.route("POST", "/api/v1/repositories", status=201,
                          body={"repository": {"id": "r2", "full_name": "acme/tool", "hook_status": "installing"}})
        code, out, _ = self.run_cli("repos", "connect", "acme/tool")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(self.last()["body"]), {"full_name": "acme/tool"})
        self.assertEqual(json.loads(out)["repository"]["id"], "r2")

        code, _, _ = self.run_cli("repos", "connect", "acme/tool", "--connection", "svc_7")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(self.last()["body"]), {"full_name": "acme/tool", "service_connection_id": "svc_7"})

    def test_repos_disconnect_deletes_the_repository(self):
        self.house.route("DELETE", "/api/v1/repositories/r2", status=204, body=None)
        code, _, _ = self.run_cli("repos", "disconnect", "r2")
        self.assertEqual(code, 0)
        self.assertEqual((self.last()["method"], self.last()["path"]), ("DELETE", "/api/v1/repositories/r2"))

    def test_watches_add_ci_sends_workflow_run_event_and_split_conclusions(self):
        self.house.route("POST", "/api/v1/watches", status=201,
                          body={"watch": {"id": "w1", "event": "workflow_run", "state": "armed"}})
        code, out, _ = self.run_cli(
            "watches", "add", "acme/widgets", "--on", "ci", "--sha", "abc1234def",
            "--workflow", "CI", "--conclusions", "success, failure", "--chat", "c1", "--wake",
            "--expires-in", "12h",
        )
        self.assertEqual(code, 0)
        req = self.last()
        self.assertEqual(req["method"], "POST")
        self.assertEqual(req["path"], "/api/v1/watches")
        self.assertEqual(json.loads(req["body"]), {
            "repository": "acme/widgets", "event": "workflow_run", "chat_id": "c1", "wake": True,
            "sha": "abc1234def", "expires_in": "12h", "workflow": "CI", "conclusions": ["success", "failure"],
        })
        self.assertEqual(json.loads(out)["watch"]["id"], "w1")

    def test_watches_add_deploy_sends_deployment_status_event_and_split_states(self):
        self.house.route("POST", "/api/v1/watches", status=201, body={"watch": {"id": "w2"}})
        code, _, _ = self.run_cli(
            "watches", "add", "acme/widgets", "--on", "deploy", "--env", "production",
            "--states", "success,failure", "--chat", "c1",
        )
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(self.last()["body"]), {
            "repository": "acme/widgets", "event": "deployment_status", "chat_id": "c1", "wake": False,
            "environment": "production", "states": ["success", "failure"],
        })

    def test_watches_add_ci_without_sha_is_a_usage_error_without_a_request(self):
        code, _, err = self.run_cli("watches", "add", "acme/widgets", "--on", "ci", "--chat", "c1")
        self.assertEqual(code, souls.EXIT_USAGE)
        self.assertEqual(self.house.requests, [])
        self.assertIn("--sha", err)

    def test_watches_add_without_chat_is_an_argparse_usage_error(self):
        # --chat is required by argparse itself (like --title on `new`); as a
        # real process that exits 2 cleanly, but called in-process it raises
        # SystemExit, same as every other required argparse option here.
        with self.assertRaises(SystemExit) as raised:
            self.run_cli("watches", "add", "acme/widgets", "--on", "deploy")
        self.assertEqual(raised.exception.code, souls.EXIT_USAGE)
        self.assertEqual(self.house.requests, [])

    def test_watches_list_passes_repository_and_state_as_query_params(self):
        self.house.route("GET", "/api/v1/watches", body={"watches": [{"id": "w1", "state": "armed"}]})
        code, out, _ = self.run_cli("watches", "list", "--repository", "acme/widgets", "--state", "armed")
        self.assertEqual(code, 0)
        req = self.last()
        self.assertIn("repository=acme%2Fwidgets", req["query"])
        self.assertIn("state=armed", req["query"])
        self.assertEqual(json.loads(out)["watches"][0]["id"], "w1")

    def test_bare_watches_defaults_to_list_with_no_filters(self):
        self.house.route("GET", "/api/v1/watches", body={"watches": []})
        code, _, _ = self.run_cli("watches")
        self.assertEqual(code, 0)
        self.assertEqual(self.last()["query"], "")

    def test_watches_show_gets_one_watch_by_id(self):
        self.house.route("GET", "/api/v1/watches/w1", body={"watch": {"id": "w1", "state": "fulfilled"}})
        code, out, _ = self.run_cli("watches", "show", "w1")
        self.assertEqual(code, 0)
        self.assertEqual(self.last()["method"], "GET")
        self.assertEqual(self.last()["path"], "/api/v1/watches/w1")
        self.assertEqual(json.loads(out)["watch"]["state"], "fulfilled")

    def test_watches_cancel_deletes_one_watch_by_id(self):
        self.house.route("DELETE", "/api/v1/watches/w1", body={"watch": {"id": "w1", "state": "cancelled"}})
        code, out, _ = self.run_cli("watches", "cancel", "w1")
        self.assertEqual(code, 0)
        self.assertEqual(self.last()["method"], "DELETE")
        self.assertEqual(self.last()["path"], "/api/v1/watches/w1")
        self.assertEqual(json.loads(out)["watch"]["state"], "cancelled")

    def test_watches_refusal_maps_to_invalid_exit_code(self):
        self.house.route("POST", "/api/v1/watches", status=422, body={"error": "A workflow watch needs the commit sha"})
        code, _, err = self.run_cli("watches", "add", "acme/widgets", "--on", "ci", "--sha", "abc1234",
                                     "--chat", "c1")
        self.assertEqual(code, souls.EXIT_INVALID)
        self.assertIn("A workflow watch needs the commit sha", err)

    def test_watch_room_tailing_still_works_unchanged_by_the_new_watches_command(self):
        # souls watch ROOM (singular) predates repository watches and must stay distinct
        # from souls watches (plural): no collision between the two top-level commands.
        self.house.route("GET", "/api/v1/conversations/c1/changes",
                          body={"changes": [], "next_since": 0, "has_more": False, "latest_revision": 0})
        code, out, _ = self.run_cli("watch", "c1", "--once", "--interval", "0", "--timeout", "0.2")
        self.assertEqual(code, souls.EXIT_TIMEOUT)
        self.assertEqual(out, "")


if __name__ == "__main__":
    unittest.main()
