"""Private CPU speaker embeddings (ECAPA). Weights are installed ahead of time; inference is offline.

POST /embed takes one WAV (mono, 16 kHz, 16-bit PCM: what FieldVoiceprints::Sample.cut
writes) and returns its 192-d embedding. The service keeps nothing and logs nothing
about requests.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hmac
import io
import json
import os
from pathlib import Path
import threading
import wave

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

import numpy as np
import torch
from speechbrain.inference.speaker import EncoderClassifier

MODEL_REVISION = "0f99f2d0ebe89ac095bcc5903c4dd8f72b367286"
DIMENSIONS = 192
SAMPLE_RATE = 16000
MAX_BYTES = 8 * 1024 * 1024
MAX_SECONDS = 120
MIN_SECONDS = 0.5
CHUNK_SECONDS = 10
MIN_TAIL_SECONDS = 2


def profile():
    import speechbrain
    return (f"ecapa-voxceleb-{MODEL_REVISION[:12]}-speechbrain-{speechbrain.__version__}"
            f"-torch-{torch.__version__.split('+')[0]}-v1")


def read_wav(data):
    """Returns float32 samples in [-1, 1], or raises ValueError."""
    with wave.open(io.BytesIO(data), "rb") as wav:
        if wav.getnchannels() != 1 or wav.getframerate() != SAMPLE_RATE or wav.getsampwidth() != 2:
            raise ValueError("format")
        frames = wav.getnframes()
        if not MIN_SECONDS * SAMPLE_RATE <= frames <= MAX_SECONDS * SAMPLE_RATE:
            raise ValueError("length")
        raw = wav.readframes(frames)
    samples = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    if samples.size == 0 or not np.any(samples):
        raise ValueError("silent")
    return samples


def chunks(samples):
    """Windows of at most CHUNK_SECONDS; a short tail joins the window before it."""
    size = CHUNK_SECONDS * SAMPLE_RATE
    starts = list(range(0, samples.size, size))
    if len(starts) > 1 and samples.size - starts[-1] < MIN_TAIL_SECONDS * SAMPLE_RATE:
        starts.pop()
    return [samples[start:(starts[i + 1] if i + 1 < len(starts) else samples.size)] for i, start in enumerate(starts)]


def embed(model, samples):
    """Unit-length mean of the unit-length embeddings of each window.

    Windowing bounds memory (one 120 s pass needs more than the accessory's 1 GB)
    and matches how the Mac script embeds: segments of at most 10 s, each
    normalised, averaged, normalised again.
    """
    vectors = []
    with torch.inference_mode():
        for window in chunks(samples):
            vector = model.encode_batch(torch.from_numpy(window.copy()).unsqueeze(0)).squeeze().numpy()
            norm = np.linalg.norm(vector)
            if vector.shape != (DIMENSIONS,) or not np.all(np.isfinite(vector)) or norm == 0:
                raise ValueError("embedding")
            vectors.append(vector / norm)
    mean = np.mean(vectors, axis=0)
    mean /= np.linalg.norm(mean)
    return [float(x) for x in mean]


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
    manifest = json.loads(Path(__file__).with_name("model-sha256.json").read_text())
    for name, expected in manifest.items():
        if hashlib.sha256((Path(args.model_dir) / name).read_bytes()).hexdigest() != expected:
            raise SystemExit("Model integrity check failed")
    torch.set_num_threads(2)
    model = EncoderClassifier.from_hparams(
        source=args.model_dir, savedir=os.environ.get("VOICE_MODEL_SAVEDIR", "/tmp/ecapa"),
        # hyperparams.yaml points its pretrainer at the Hub repo; point it at the
        # verified local copy so nothing is fetched at run time.
        overrides={"pretrained_path": args.model_dir},
        run_opts={"device": "cpu"})
    model.eval()
    # Warm inference on synthetic audio before publishing readiness.
    rng = np.random.default_rng(0)
    embed(model, (rng.standard_normal(SAMPLE_RATE * 2) * 0.1).astype(np.float32))
    current = profile()
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
            data = self.rfile.read(size)
            if not gate.acquire(timeout=30):
                return self.reply(503, {"error": "Busy"})
            try:
                samples = read_wav(data)
                self.reply(200, {"embedding": embed(model, samples), "profile": current})
            except Exception:
                self.reply(400, {"error": "Invalid audio"})
            finally:
                gate.release()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    if args.ready_file:
        path = Path(args.ready_file)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as file:
            json.dump({"url": f"http://127.0.0.1:{server.server_port}", "profile": current, "pid": os.getpid()}, file)
    server.serve_forever()


if __name__ == "__main__":
    main()
