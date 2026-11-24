"""soulshouse-appearance: offline payload/output tests and loopback HTTP tests."""

import contextlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import threading
import unittest
from unittest import mock


def load_helper():
    loader = importlib.machinery.SourceFileLoader(
        "soulshouse_appearance",
        str(Path(__file__).resolve().parents[2] / "agent-runtime" / "soulshouse-appearance"),
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


appearance = load_helper()


class OfflineFormattingAndArgsTests(unittest.TestCase):
    def parse_patch(self, argv):
        args = appearance.build_parser().parse_args(argv)
        return appearance.build_patch_payload(args)

    def test_set_builds_partial_payloads_and_supports_us_spelling_alias(self):
        self.assertEqual({"colour": "teal"}, self.parse_patch(["set", "--colour", "teal"]))
        self.assertEqual({"colour": "teal"}, self.parse_patch(["set", "--color", "  teal  "]))
        self.assertEqual({"icon": "Leaf"}, self.parse_patch(["set", "--icon", "Leaf"]))
        self.assertEqual({"colour": "teal", "icon": "Leaf"},
                         self.parse_patch(["set", "--colour", "teal", "--icon", "Leaf"]))

    def test_set_clears_via_flags_or_none_keyword(self):
        self.assertEqual({"colour": None}, self.parse_patch(["set", "--clear-colour"]))
        self.assertEqual({"colour": None}, self.parse_patch(["set", "--clear-color"]))
        self.assertEqual({"colour": None}, self.parse_patch(["set", "--colour", "none"]))
        self.assertEqual({"icon": None}, self.parse_patch(["set", "--clear-icon"]))
        self.assertEqual({"icon": None}, self.parse_patch(["set", "--icon", "NONE"]))

    def test_clear_subcommand_clears_both_by_default_or_selected_field(self):
        self.assertEqual({"colour": None, "icon": None}, self.parse_patch(["clear"]))
        self.assertEqual({"colour": None}, self.parse_patch(["clear", "--colour"]))
        self.assertEqual({"icon": None}, self.parse_patch(["clear", "--icon"]))

    def test_set_refuses_empty_or_conflicting_flags(self):
        for bad in (
            ["set"],
            ["set", "--colour", "teal", "--clear-colour"],
            ["set", "--icon", "Leaf", "--clear-icon"],
        ):
            with self.assertRaises(ValueError):
                self.parse_patch(bad)

    def test_format_show_marks_current_choices_and_handles_unset_defaults(self):
        lines = appearance.format_show_lines({
            "colour": "teal",
            "icon": "Leaf",
            "avatar_url": "/rails/active_storage/blobs/a.png",
            "colours": ["slate", "teal", "violet"],
            "icons": ["Eye", "Leaf"],
        })
        self.assertIn("Colour: teal", lines)
        self.assertIn("Icon: Leaf", lines)
        self.assertIn("Picture: /rails/active_storage/blobs/a.png", lines)
        self.assertIn("Colours: slate, *teal, violet", lines)
        self.assertIn("Icons: Eye, *Leaf", lines)

        unset = appearance.format_show_lines({
            "colour": None,
            "icon": None,
            "avatar_url": None,
            "colours": ["teal"],
            "icons": ["Leaf"],
        })
        self.assertIn("Colour: none (default)", unset)
        self.assertIn("Icon: none (default)", unset)
        self.assertIn("Picture: none", unset)
        self.assertIn("Colours: teal", unset)
        self.assertIn("Icons: Leaf", unset)


class LoopbackHttpTests(unittest.TestCase):
    def setUp(self):
        self.requests = []
        self.next_status = 200
        self.next_location = None
        self.next_body = {
            "colour": "teal",
            "icon": "Leaf",
            "avatar_url": None,
            "colours": ["slate", "teal"],
            "icons": ["Eye", "Leaf"],
        }
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def handle_req(self):
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length).decode("utf-8") if length else None
                outer.requests.append({
                    "method": self.command,
                    "path": self.path,
                    "auth": self.headers.get("Authorization"),
                    "body": json.loads(raw) if raw else None,
                })
                if outer.next_location:
                    self.send_response(outer.next_status)
                    self.send_header("Location", outer.next_location)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                encoded = json.dumps(outer.next_body).encode("utf-8")
                self.send_response(outer.next_status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            do_GET = do_PATCH = handle_req

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def run_cli(self, argv, env_overrides=None):
        env = {
            "SOULSHOUSE_APP_URL": self.base_url,
            "SOULSHOUSE_BEARER_TOKEN": "test-resident-token",
        }
        if env_overrides is not None:
            env.update(env_overrides)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, env, clear=True):
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = appearance.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_bare_command_fetches_appearance_and_supports_json_mode(self):
        code, out, err = self.run_cli([])
        self.assertEqual(0, code, err)
        self.assertEqual("GET", self.requests[-1]["method"])
        self.assertEqual("/api/v1/agent/appearance", self.requests[-1]["path"])
        self.assertEqual("Bearer test-resident-token", self.requests[-1]["auth"])
        self.assertIn("Colours: slate, *teal", out)

        code, out, _ = self.run_cli(["--json"])
        self.assertEqual(0, code)
        self.assertEqual("teal", json.loads(out)["colour"])

    def test_set_sends_patch_and_legacy_helixkit_env_falls_back(self):
        self.next_body = {"colour": "teal", "icon": "Leaf", "avatar_url": None}
        code, out, err = self.run_cli(
            ["set", "--colour", "teal", "--icon", "Leaf"],
            env_overrides={
                "SOULSHOUSE_APP_URL": "",
                "SOULSHOUSE_BEARER_TOKEN": "",
                "HELIXKIT_APP_URL": self.base_url,
                "HELIXKIT_BEARER_TOKEN": "legacy-token",
            },
        )
        self.assertEqual(0, code, err)
        self.assertEqual("PATCH", self.requests[-1]["method"])
        self.assertEqual("Bearer legacy-token", self.requests[-1]["auth"])
        self.assertEqual({"colour": "teal", "icon": "Leaf"}, self.requests[-1]["body"])
        self.assertEqual("Appearance updated: colour=teal, icon=Leaf\n", out)

    def test_http_errors_and_redirects_fail_cleanly_without_leaking_token(self):
        self.next_status = 422
        self.next_body = {"errors": ["Icon is not included in the list"]}
        code, _, err = self.run_cli(["set", "--icon", "Waveform"])
        self.assertEqual(1, code)
        self.assertIn("HTTP 422: Icon is not included in the list", err)
        self.assertNotIn("test-resident-token", err)

        self.next_status = 302
        self.next_location = f"{self.base_url}/elsewhere"
        code, out, err = self.run_cli(["show"])
        self.assertEqual(1, code)
        self.assertIn("refused to follow a redirect (302)", err)
        self.assertNotIn("test-resident-token", out + err)
        self.assertEqual(2, len(self.requests))

    def test_missing_credentials_exit_65(self):
        code, _, err = self.run_cli([], env_overrides={"SOULSHOUSE_APP_URL": "", "SOULSHOUSE_BEARER_TOKEN": ""})
        self.assertEqual(65, code)
        self.assertIn("missing", err)


if __name__ == "__main__":
    unittest.main()
