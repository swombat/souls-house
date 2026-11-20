import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

HELPER = Path(__file__).resolve().parents[2] / "agent-runtime" / "soulshouse-computer"


class FakeHouse(BaseHTTPRequestHandler):
    requests = []
    body = b"result bytes"

    def log_message(self, *args):
        pass

    def reply(self, status, body, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        FakeHouse.requests.append(("POST", self.path))
        self.reply(202, json.dumps({"id": "op1", "state": "completed", "outcome": "ok", "body_available": True}).encode())

    def do_GET(self):
        FakeHouse.requests.append(("GET", self.path))
        if self.path.endswith("/body"):
            self.reply(200, FakeHouse.body, "application/octet-stream")
        else:
            self.reply(200, json.dumps({"id": "op1", "state": "completed", "body_available": True}).encode())


class SoulshouseComputerTest(unittest.TestCase):
    def setUp(self):
        FakeHouse.requests = []
        FakeHouse.body = b"result bytes"
        self.server = HTTPServer(("127.0.0.1", 0), FakeHouse)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = dict(os.environ, SOULSHOUSE_APP_URL=f"http://127.0.0.1:{self.server.server_port}",
                        SOULSHOUSE_BEARER_TOKEN="synthetic-token")

    def run_helper(self, *args):
        return subprocess.run(["python3", str(HELPER), *args], env=self.env, capture_output=True, text=True, timeout=30)

    def test_unwritable_destination_sends_nothing(self):
        out = os.path.join(self.tmp.name, "missing", "result.bin")
        result = self.run_helper("run", "WemMeN", "read", "--arg", "volume=v", "--arg", "path=p", "--out", out)
        self.assertEqual(result.returncode, 1)
        self.assertIn("not sent", result.stderr)
        self.assertEqual(FakeHouse.requests, [])

    def test_result_is_saved_and_no_staging_file_is_left(self):
        out = os.path.join(self.tmp.name, "result.bin")
        Path(out).write_bytes(b"old")
        result = self.run_helper("run", "WemMeN", "read", "--arg", "volume=v", "--arg", "path=p", "--out", out)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(out).read_bytes(), b"result bytes")
        self.assertEqual(os.listdir(self.tmp.name), ["result.bin"])
        self.assertEqual([r[0] for r in FakeHouse.requests], ["POST", "GET"])
        self.assertTrue(FakeHouse.requests[1][1].endswith("/op1/body"))

    def test_oversized_result_leaves_the_existing_file_alone(self):
        FakeHouse.body = b"x" * (8 * 1024 * 1024 + 1)
        out = os.path.join(self.tmp.name, "result.bin")
        Path(out).write_bytes(b"old")
        result = self.run_helper("run", "WemMeN", "read", "--arg", "volume=v", "--arg", "path=p", "--out", out)
        self.assertEqual(result.returncode, 1)
        self.assertIn("op1", result.stderr)
        self.assertEqual(Path(out).read_bytes(), b"old")
        self.assertEqual(os.listdir(self.tmp.name), ["result.bin"])


if __name__ == "__main__":
    unittest.main()
