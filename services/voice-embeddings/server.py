"""Private CPU speaker embeddings (WeSpeaker). Verified local weights only.

POST /embed takes one WAV (mono, 16 kHz, 16-bit PCM: what FieldVoiceprints::Sample.cut
writes) and returns its 256-d embedding. The service keeps nothing and logs nothing
about requests.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hmac
import json
import os
from importlib.metadata import version
from pathlib import Path
import threading

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["PYANNOTE_METRICS_ENABLED"] = "0"
os.environ["DO_NOT_TRACK"] = "1"

import numpy as np
import torch
from pyannote.audio import Inference, Model

from wav import SAMPLE_RATE, pcm16_mono

MODEL_REVISION = "837717ddb9ff5507820346191109dc79c958d614"
DIMENSIONS = 256
MAX_BYTES = 8 * 1024 * 1024


def profile():
    if version("pyannote.audio") != "4.0.7" or torch.__version__.split("+")[0] != "2.14.1":
        raise RuntimeError("Embedding profile requires the pinned library versions")
    return "wespeaker-voxceleb-837717ddb9ff-pyannote-4.0.7-torch-2.14.1-whole-v1"


def read_wav(data):
    """Returns float32 samples in [-1, 1], or raises ValueError (see wav.pcm16_mono)."""
    return np.frombuffer(pcm16_mono(data), dtype="<i2").astype(np.float32) / 32768.0


def embed(model, samples):
    """One whole-clip Inference call, then L2 normalization; no windows."""
    with torch.inference_mode():
        vector = np.asarray(model({"waveform": torch.from_numpy(samples.copy()).unsqueeze(0),
                                   "sample_rate": SAMPLE_RATE}))
    # Inference(window="whole") returns a flat vector for a single waveform.
    if vector.shape != (DIMENSIONS,):
        raise ValueError("embedding")
    vector = vector.astype(np.float64)
    norm = np.linalg.norm(vector)
    if not np.all(np.isfinite(vector)) or not np.isfinite(norm) or norm == 0:
        raise ValueError("embedding")
    return (vector / norm).tolist()


def load_model(model_dir):
    """The single checkpoint is sufficient: architecture/config live inside it."""
    model_dir = Path(model_dir)
    manifest = json.loads(Path(__file__).with_name("model-sha256.json").read_text())
    if set(manifest) != {"pytorch_model.bin"}:
        raise RuntimeError("Invalid model integrity manifest")
    checkpoint = model_dir / "pytorch_model.bin"
    if hashlib.sha256(checkpoint.read_bytes()).hexdigest() != manifest["pytorch_model.bin"]:
        raise RuntimeError("Model integrity check failed")
    model = Model.from_pretrained(str(checkpoint), map_location="cpu")
    model.eval()
    return Inference(model, window="whole", device=torch.device("cpu"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--ready-file")
    args = parser.parse_args()
    token = os.environ.get("VOICE_EMBEDDING_TOKEN")
    if not token or len(token) < 24:
        raise SystemExit("A private embedding token of at least 24 characters is required")
    current = profile()
    torch.set_num_threads(2)
    torch.set_num_interop_threads(1)
    model = load_model(args.model_dir)
    # Warm inference on synthetic audio before publishing readiness.
    rng = np.random.default_rng(0)
    embed(model, (rng.standard_normal(SAMPLE_RATE * 2) * 0.1).astype(np.float32))
    server = make_server(model, token, current, args.host, args.port)
    if args.ready_file:
        path = Path(args.ready_file)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as file:
            json.dump({"url": f"http://127.0.0.1:{server.server_port}", "profile": current, "pid": os.getpid()}, file)
    server.serve_forever()


def make_server(model, token, current, host="127.0.0.1", port=8080):
    gate = threading.BoundedSemaphore(1)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # No paths, audio, credentials or response bodies in logs.

        def setup(self):
            super().setup()
            self.connection.settimeout(10)

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
                self.reply(200, {"ready": True, "profile": current, "dimensions": DIMENSIONS})
            else:
                self.reply(404, {"error": "Not found"})

        def do_POST(self):
            if self.path != "/embed":
                return self.reply(404, {"error": "Not found"})
            if not hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {token}"):
                return self.reply(401, {"error": "Unauthorized"})
            try:
                size = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                return self.reply(400, {"error": "Invalid request"})
            if not 0 < size <= MAX_BYTES or self.headers.get("Transfer-Encoding"):
                return self.reply(400, {"error": "Invalid request"})
            if not gate.acquire(timeout=30):
                return self.reply(503, {"error": "Busy"})
            try:
                data = self.rfile.read(size)
                if len(data) != size:
                    raise ValueError("truncated")
                samples = read_wav(data)
                self.reply(200, {"embedding": embed(model, samples), "profile": current})
            except Exception:
                self.reply(400, {"error": "Invalid audio"})
            finally:
                gate.release()

    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    return server


if __name__ == "__main__":
    main()
