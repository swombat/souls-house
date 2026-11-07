"""Credential-safe tests: explicit subprocess environment, localhost only."""

import http.server
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "agent-runtime" / "soulshouse-share"
loader = importlib.machinery.SourceFileLoader("share", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
share = importlib.util.module_from_spec(spec)
loader.exec_module(share)


def ui(kind="Text", props=None):
    return {"version": 1, "root": "main", "elements": {
        "main": {"type": kind, "props": props if props is not None else {"text": "Hello"}}
    }}


class ValidationTest(unittest.TestCase):
    def reject(self, value, field):
        with self.assertRaisesRegex(ValueError, field):
            share.validate(value)

    def test_static_catalog_and_primitive_cells(self):
        for kind, props in [
            ("Stack", {}), ("Card", {"title": "Title"}), ("Text", {"text": "Hello"}),
            ("Metric", {"label": "Jobs", "value": "2", "detail": "Two remaining"}),
            ("Table", {"columns": ["A", "B", "C", "D"], "rows": [["", True, None, 1.5]]}),
            ("Chart", {"kind": "line", "labels": ["A"], "series": [{"name": "S", "values": [1]}]}),
        ]:
            with self.subTest(kind=kind):
                value = ui(kind, props)
                value["elements"]["main"]["children"] = []
                self.assertEqual(value, share.validate(value))

    def test_unknown_and_missing_fields(self):
        for value, field in [
            (dict(ui(), extra=1), "rich_ui"),
            (dict(ui(), version=True), "version"),
            (ui("Script", {}), "type"),
            (ui("Text", {}), "props"),
            (ui("Text", {"text": {"$expr": "secret"}}), "text"),
            (ui("Text", {"text": "hi", "onClick": "go"}), "props"),
            (ui("Metric", {"label": "Jobs", "value": 2}), "value"),
            (ui("Card", {"title": " "}), "title"),
            (ui("Text", {"text": "\0"}), "text"),
        ]:
            with self.subTest(field=field, value=value):
                self.reject(value, field)

    def test_optional_fallback_contract(self):
        share.validate(dict(ui(), fallback="Readable generated summary"))
        for fallback in (None, {}, 12, "", " ", "bad\0text", "x" * 3501):
            self.reject(dict(ui(), fallback=fallback), "fallback")

    def test_table_bounds_and_cells(self):
        for props, field in [
            ({"columns": [], "rows": []}, "columns"),
            ({"columns": ["A"] * 21, "rows": []}, "columns"),
            ({"columns": ["A"], "rows": [[1]] * 501}, "rows"),
            ({"columns": ["A"], "rows": [[1, 2]]}, "rows"),
            ({"columns": ["A"], "rows": [[{"text": "bad"}]]}, "rows"),
            ({"columns": ["A"], "rows": [[[]]]}, "rows"),
            ({"columns": ["A"], "rows": [[float("inf")]]}, "rows"),
            ({"columns": ["A"], "rows": [["x" * 4001]]}, "rows"),
            ({"columns": ["A"], "rows": [["\0"]]}, "rows"),
        ]:
            self.reject(ui("Table", props), field)

    def test_chart_bounds(self):
        valid = {"kind": "bar", "labels": ["A"], "series": [{"name": "S", "values": [2]}]}
        for key, value in [
            ("kind", "pie"), ("kind", {}), ("labels", []), ("labels", ["x"] * 201),
            ("series", []), ("series", valid["series"] * 9),
            ("series", [{"name": "S", "values": []}]),
            ("series", [{"name": "S", "values": [True]}]),
            ("series", [{"name": "S", "values": [float("nan")]}]),
            ("series", [{"name": "S", "values": [1], "extra": 1}]),
        ]:
            self.reject(ui("Chart", dict(valid, **{key: value})), key)

    def test_trees(self):
        value = ui("Stack", {})
        value["elements"]["main"]["children"] = ["missing"]
        self.reject(value, "dangling")
        value["elements"]["main"]["children"] = ["main"]
        self.reject(value, "cycle")
        value["elements"]["child"] = {"type": "Text", "props": {"text": "child"}}
        value["elements"]["main"]["children"] = ["child", "child"]
        self.reject(value, "shared")
        value["elements"]["main"]["children"] = []
        self.reject(value, "unreachable")
        value = ui()
        value["elements"]["main"]["children"] = ["main"]
        self.reject(value, "children")
        for length in (10, 11, 51):
            value = {"version": 1, "root": "n0", "elements": {
                f"n{i}": {"type": "Stack", "props": {}, "children": [f"n{i+1}"] if i < length - 1 else []}
                for i in range(length)
            }}
            if length == 10:
                share.validate(value)
            else:
                self.reject(value, "depth|elements")

    def test_ids_string_and_byte_limits(self):
        for bad in ("", "a.b", "a" * 65, "__proto__", "constructor", "prototype"):
            value = ui()
            value["root"] = bad
            self.reject(value, "root")
        share.validate(ui("Text", {"text": "é" * 4000}))
        self.reject(ui("Text", {"text": "x" * 4001}), "text")
        self.reject(ui("Card", {"title": "x" * 201}), "title")
        value = ui("Table", {"columns": ["A"], "rows": [["é" * 4000]] * 40})
        self.reject(value, "256 KiB")

    def test_numeric_fidelity_boundaries(self):
        maximum = 9_007_199_254_740_991
        for value in (maximum, -maximum, float(maximum), float(-maximum), 0, 1.25, -1.25):
            with self.subTest(valid=value):
                share.validate(ui("Table", {"columns": ["A"], "rows": [[value]]}))
                share.validate(ui("Chart", {"kind": "line", "labels": ["A"],
                                           "series": [{"name": "S", "values": [value]}]}))
        for value in (maximum + 1, -maximum - 1, float(maximum + 1),
                      float(-maximum - 1), 1e30, 10 ** 400):
            with self.subTest(invalid=value):
                self.reject(ui("Table", {"columns": ["A"], "rows": [[value]]}), "rows")
                self.reject(ui("Chart", {"kind": "line", "labels": ["A"],
                                        "series": [{"name": "S", "values": [value]}]}), "values")
        share.validate(ui("Table", {"columns": ["Exact count"], "rows": [[str(maximum + 1)]]}))

    def test_dry_run_never_reads_environment_or_network(self):
        def environment_get(key, default=None):
            if key.startswith(("SOULSHOUSE_", "HELIXKIT_")):
                raise AssertionError("credential/runtime environment read")
            return default

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "data.csv"
            path.write_text("Code,Flag\n001,true\n")
            with patch.object(sys, "argv", [str(SCRIPT), "table", "chat", "--file", str(path), "--dry-run"]), \
                    patch.object(share.os.environ, "get", side_effect=environment_get), \
                    patch.object(share.urllib.request, "build_opener", side_effect=AssertionError("network")), \
                    patch("builtins.print") as output:
                self.assertEqual(0, share.main())
            payload = json.loads(output.call_args.args[0])
            self.assertNotIn("runtime_run_id", payload)
            self.assertEqual(["001", "true"], payload["rich_ui"]["elements"]["main"]["props"]["rows"][0])


class CliTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "input"
        self.path.write_text("Code,Value\n001,true\n002,=SUM(A1)\n")

    def run_cli(self, *args, env=None):
        # Do not inherit bearer keys, proxy configuration, HOME or house endpoints.
        return subprocess.run([sys.executable, str(SCRIPT), *args], env={
            "PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", **(env or {})
        }, text=True, capture_output=True, timeout=10)

    def test_help_catalog_validate_and_csv_preview(self):
        self.assertIn("catalog", self.run_cli("--help").stdout)
        self.assertEqual(6, len(json.loads(self.run_cli("catalog").stdout)["components"]))
        result = self.run_cli("table", "chat", "--file", str(self.path), "--title", "Results",
                              "--caption", "Caption", "--dry-run")
        self.assertEqual(0, result.returncode, result.stderr)
        body = json.loads(result.stdout)
        self.assertIn("Caption\n\nResults", body["content"])
        self.assertIn("Code: 001", body["content"])
        self.assertEqual("Caption\n\n" + body["rich_ui"]["fallback"], body["content"])
        self.assertNotIn("Caption", body["rich_ui"]["fallback"])
        self.assertEqual("=SUM(A1)", body["rich_ui"]["elements"]["main"]["props"]["rows"][1][1])
        self.path.write_text(json.dumps(body["rich_ui"]))
        self.assertEqual(0, self.run_cli("validate", "--file", str(self.path)).returncode)

    def test_chart_defaults_override_and_caption(self):
        self.path.write_text(json.dumps({"labels": ["Mon", "Tue"], "series": [{"name": "Jobs", "values": [2, 5]}]}))
        result = self.run_cli("chart", "chat", "--file", str(self.path), "--dry-run")
        self.assertEqual(0, result.returncode, result.stderr)
        body = json.loads(result.stdout)
        self.assertIn("2 → 5", body["content"])
        self.assertEqual(body["content"], body["rich_ui"]["fallback"])
        self.assertEqual("line", body["rich_ui"]["elements"]["main"]["props"]["kind"])
        result = self.run_cli("chart", "chat", "--file", str(self.path), "--kind", "bar", "--dry-run")
        self.assertEqual("bar", json.loads(result.stdout)["rich_ui"]["elements"]["main"]["props"]["kind"])

    def test_ui_replaces_incoming_marker_and_blank_caption_is_not_a_caption(self):
        self.path.write_text(json.dumps(dict(ui(), fallback="Stale fallback")))
        result = self.run_cli("ui", "chat", "--file", str(self.path), "--caption", " \n ", "--dry-run")
        self.assertEqual(0, result.returncode, result.stderr)
        body = json.loads(result.stdout)
        self.assertEqual("Hello", body["content"])
        self.assertEqual(body["content"], body["rich_ui"]["fallback"])

    def test_invalid_files_no_post(self):
        for text in ('{"version":1,"version":1}', "{", "[]"):
            self.path.write_text(text)
            result = self.run_cli("validate", "--file", str(self.path))
            self.assertNotEqual(0, result.returncode)
            self.assertNotIn("Traceback", result.stderr)
        self.path.write_text("A,B\none\n")
        self.assertIn("width", self.run_cli("table", "chat", "--file", str(self.path), "--dry-run").stderr)

    def test_localhost_auth_receipt_show_redirect_and_ambiguous_failure(self):
        calls = []
        mode = {"value": "ok"}
        token = "synthetic-test-token"

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                calls.append((self.command, self.path, self.headers.get("Authorization"), body))
                if mode["value"] == "drop":
                    self.connection.close()
                    return
                if mode["value"] == "redirect":
                    self.send_response(307)
                    self.send_header("Location", "/stolen?token=" + token)
                    self.end_headers()
                    return
                if mode["value"] == "invalid":
                    self.send_response(422)
                    self.end_headers()
                    self.wfile.write(json.dumps({
                        "errors": ["rich_ui.elements.main.props.rows: width must match columns",
                                   "Credential " + token] + ["bounded " + "x" * 800] * 12,
                        "error": "rich_ui.version: must be 1",
                        "raw_private_payload": "DO_NOT_PRINT_RAW_BODY",
                        "rich_ui": {"private": "DO_NOT_PRINT_SPEC"}
                    }).encode())
                    return
                self.send_response(201)
                self.end_headers()
                self.wfile.write(json.dumps({
                    "message": {"id": "m1", "revision": 3, "rich_ui": body["rich_ui"],
                                "content_html": "large unwanted html", "rich_ui_summary": "Table summary"},
                    "reflexes": [{"name": "Check", "reminder": "Remember"}]
                }).encode())

            def do_GET(self):
                calls.append((self.command, self.path, self.headers.get("Authorization"), None))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps({"message_id": "m1", "revision": 3, "rich_ui": ui()}).encode())

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        env = {"HELIXKIT_APP_URL": f"http://127.0.0.1:{server.server_port}",
               "HELIXKIT_BEARER_TOKEN": token, "SOULSHOUSE_RUNTIME_CHAT_ID": "chat",
               "SOULSHOUSE_RUNTIME_RUN_ID": "run1"}
        result = self.run_cli("table", "chat", "--file", str(self.path), env=env)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("Bearer " + token, calls[-1][2])
        self.assertEqual("run1", calls[-1][3]["runtime_run_id"])
        receipt = json.loads(result.stdout)
        self.assertEqual("m1", receipt["id"])
        self.assertTrue(receipt["posted"])
        self.assertNotIn("rich_ui", receipt)
        self.assertNotIn("content_html", receipt)
        self.assertIn("reflex Check: Remember", result.stderr)
        self.assertNotIn(token, result.stdout + result.stderr)
        result = self.run_cli("table", "other", "--file", str(self.path), env=env)
        self.assertNotIn("runtime_run_id", calls[-1][3])
        result = self.run_cli("show", "chat", "m1", env=env)
        self.assertEqual("GET", calls[-1][0])
        self.assertEqual("/api/v1/conversations/chat/messages/m1/rich_ui", calls[-1][1])
        self.assertEqual(ui(), json.loads(result.stdout)["rich_ui"])
        mode["value"] = "invalid"
        before = len(calls)
        result = self.run_cli("table", "chat", "--file", str(self.path), env=env)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(before + 1, len(calls))
        self.assertIn("rich_ui.elements.main.props.rows", result.stderr)
        self.assertIn("rich_ui.version", result.stderr)
        self.assertIn("[REDACTED]", result.stderr)
        self.assertNotIn(token, result.stdout + result.stderr)
        self.assertNotIn("DO_NOT_PRINT", result.stdout + result.stderr)
        self.assertLessEqual(len(result.stderr.splitlines()), 9)
        self.assertLess(len(result.stderr), 1750)
        for failure in ("redirect", "drop"):
            mode["value"] = failure
            before = len(calls)
            result = self.run_cli("table", "chat", "--file", str(self.path), env=env)
            self.assertNotEqual(0, result.returncode)
            self.assertEqual(before + 1, len(calls), "must not retry or follow redirect")
            self.assertNotIn(token, result.stdout + result.stderr)
            if failure == "drop":
                self.assertIn("ambiguous", result.stderr)


if __name__ == "__main__":
    unittest.main()
