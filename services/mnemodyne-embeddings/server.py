"""Private CPU embeddings. Weights are installed ahead of time; inference is offline."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hmac
import json
import os
from pathlib import Path
import threading

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
from fastembed import TextEmbedding

PROFILE = "bge-small-en-v1.5-q-52398278842e-fastembed-0.7.4-v1"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--ready-file")
    args = parser.parse_args()
    token = os.environ.get("MNEMODYNE_EMBEDDING_TOKEN")
    if not token or len(token) < 24:
        raise SystemExit("A private embedding token of at least 24 characters is required")
    manifest = json.loads(Path(__file__).with_name("model-sha256.json").read_text())
    for name, expected in manifest.items():
        if hashlib.sha256((Path(args.model_dir) / name).read_bytes()).hexdigest() != expected:
            raise SystemExit("Model integrity check failed")
    model = TextEmbedding("BAAI/bge-small-en-v1.5", specific_model_path=args.model_dir,
                          local_files_only=True, threads=2)
    # Warm inference before publishing readiness.
    list(model.embed(["Synthetic readiness probe"]))
    gate = threading.BoundedSemaphore(1)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # No paths, text, credentials or response bodies in logs.

        def setup(self):
            super().setup()
            self.connection.settimeout(3)

        def reply(self, status, payload):
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/health":
                self.reply(200, {"ready": True, "profile": PROFILE, "dimensions": 384})
            else:
                self.reply(404, {"error": "Not found"})

        def do_POST(self):
            if self.path != "/v1/embeddings":
                return self.reply(404, {"error": "Not found"})
            if not hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {token}"):
                return self.reply(401, {"error": "Unauthorized"})
            if not gate.acquire(timeout=0.5):
                return self.reply(503, {"error": "Busy"})
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 < size <= 32768 or self.headers.get("Transfer-Encoding"):
                    return self.reply(400, {"error": "Invalid request"})
                data = json.loads(self.rfile.read(size))
                if not isinstance(data, dict) or data.get("model") != PROFILE:
                    return self.reply(400, {"error": "Invalid profile"})
                text = data.get("input")
                if not isinstance(text, str) or not 0 < len(text) <= 6003:
                    return self.reply(400, {"error": "Invalid input"})
                vector = next(model.embed([text])).tolist()
                self.reply(200, {"model": PROFILE, "data": [{"embedding": vector}]})
            except Exception:
                self.reply(400, {"error": "Invalid request"})
            finally:
                gate.release()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    if args.ready_file:
        path = Path(args.ready_file)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as file:
            json.dump({"url": f"http://127.0.0.1:{server.server_port}", "profile": PROFILE, "pid": os.getpid()}, file)
    server.serve_forever()


if __name__ == "__main__":
    main()
