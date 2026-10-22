"""Mocked engine + real loopback HTTP contract. Requires numpy, not model packages."""
import contextlib
import hashlib
import http.client
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import Mock, patch

import numpy as np

SERVICE = Path(__file__).resolve().parent.parent / "services/voice-embeddings"
sys.path.insert(0, str(SERVICE))
from voice_embeddings_wav_test import make

torch = types.ModuleType("torch")
torch.__version__ = "2.14.1+cpu"
torch.inference_mode = contextlib.nullcontext
torch.from_numpy = lambda value: types.SimpleNamespace(unsqueeze=lambda axis: np.expand_dims(value, axis))
torch.device = lambda value: value
audio = types.ModuleType("pyannote.audio")
audio.Model = Mock()
audio.Inference = Mock()
spec = importlib.util.spec_from_file_location("voice_server", SERVICE / "server.py")
server = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, {"torch": torch, "pyannote": types.ModuleType("pyannote"), "pyannote.audio": audio}):
    spec.loader.exec_module(server)

PROFILE = "wespeaker-voxceleb-837717ddb9ff-pyannote-4.0.7-torch-2.14.1-whole-v1"
TOKEN = "synthetic-test-token-not-a-credential"


class EngineContractTest(unittest.TestCase):
    def test_offline_and_metrics_disabled(self):
        for key, value in {"HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
                           "PYANNOTE_METRICS_ENABLED": "0", "DO_NOT_TRACK": "1"}.items():
            self.assertEqual(value, os.environ[key])
        source = (SERVICE / "server.py").read_text()
        self.assertLess(source.index('os.environ["PYANNOTE_METRICS_ENABLED"]'),
                        source.index("from pyannote.audio"))

    def test_profile_is_exact_and_rejects_version_drift(self):
        with patch.object(server, "version", return_value="4.0.7"):
            self.assertEqual(PROFILE, server.profile())
        with patch.object(server, "version", return_value="4.0.8"), self.assertRaises(RuntimeError):
            server.profile()
        with patch.object(server, "version", return_value="4.0.7"), patch.object(torch, "__version__", "2.15.0"):
            with self.assertRaises(RuntimeError):
                server.profile()

    def test_whole_clip_once_including_120_seconds_and_unit_output(self):
        model = Mock(return_value=np.arange(1, 257, dtype=np.float32))
        samples = np.ones(120 * 16000, dtype=np.float32)
        result = server.embed(model, samples)
        model.assert_called_once()
        argument = model.call_args.args[0]
        self.assertEqual(16000, argument["sample_rate"])
        self.assertEqual((1, 120 * 16000), argument["waveform"].shape)
        np.testing.assert_array_equal(samples, argument["waveform"][0])
        self.assertEqual(256, len(result))
        self.assertAlmostEqual(1, np.linalg.norm(result), places=12)
        self.assertTrue(all(type(x) is float for x in result))

    def test_rejects_wrong_dimensions_zero_and_nonfinite(self):
        for vector in (np.ones(192), np.ones((1, 256)), np.zeros(256),
                       np.full(256, np.nan), np.full(256, np.inf)):
            with self.subTest(shape=vector.shape), self.assertRaises(ValueError):
                server.embed(Mock(return_value=vector), np.ones(8000, dtype=np.float32))

    def test_only_verified_local_checkpoint_reaches_loader(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkpoint = root / "pytorch_model.bin"
            checkpoint.write_bytes(b"public synthetic checkpoint fixture")
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"pytorch_model.bin": hashlib.sha256(checkpoint.read_bytes()).hexdigest()}))
            with patch.object(server.Path, "with_name", return_value=manifest):
                audio.Model.reset_mock()
                audio.Inference.reset_mock()
                server.load_model(root)
                audio.Model.from_pretrained.assert_called_once_with(str(checkpoint), map_location="cpu")
                model = audio.Model.from_pretrained.return_value
                model.eval.assert_called()
                audio.Inference.assert_called_once_with(model, window="whole", device="cpu")
                audio.Model.reset_mock()
                checkpoint.write_bytes(b"tampered")
                with self.assertRaises(RuntimeError):
                    server.load_model(root)
                audio.Model.from_pretrained.assert_not_called()
                checkpoint.unlink()
                with self.assertRaises(FileNotFoundError):
                    server.load_model(root)

    def test_public_manifest_matches_pinned_checkpoint(self):
        manifest = json.loads((SERVICE / "model-sha256.json").read_text())
        self.assertEqual({"pytorch_model.bin": "366edf44f4c80889a3eb7a9d7bdf02c4aede3127f7dd15e274dcdb826b143c56"}, manifest)

    def test_startup_rejects_short_token_before_loading(self):
        with patch.object(sys, "argv", ["server.py", "--model-dir", "/not-a-model"]), \
                patch.dict(os.environ, {"VOICE_EMBEDDING_TOKEN": "short"}), \
                patch.object(server, "load_model") as loader, self.assertRaises(SystemExit):
            server.main()
        loader.assert_not_called()

    def test_no_ready_server_or_file_when_integrity_or_warmup_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            ready = Path(directory) / "ready.json"
            for failure in ("load", "warmup"):
                with self.subTest(failure=failure), \
                        patch.object(sys, "argv", ["server.py", "--model-dir", directory,
                                                   "--ready-file", str(ready)]), \
                        patch.dict(os.environ, {"VOICE_EMBEDDING_TOKEN": TOKEN}), \
                        patch.object(server, "profile", return_value=PROFILE), \
                        patch.object(torch, "set_num_threads", create=True), \
                        patch.object(torch, "set_num_interop_threads", create=True), \
                        patch.object(server, "load_model", side_effect=RuntimeError("integrity") if failure == "load" else None), \
                        patch.object(server, "embed", side_effect=RuntimeError("warmup") if failure == "warmup" else None), \
                        patch.object(server, "make_server") as listener:
                    with self.assertRaises(RuntimeError):
                        server.main()
                    listener.assert_not_called()
                    self.assertFalse(ready.exists())


class BuildDownloadTest(unittest.TestCase):
    def test_revision_url_and_integrity_before_write(self):
        spec = importlib.util.spec_from_file_location("voice_download", SERVICE / "download.py")
        download = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(download)
        fixture = b"synthetic public checkpoint fixture"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"pytorch_model.bin": hashlib.sha256(fixture).hexdigest()}))
            target = root / "model"
            with patch.object(download.Path, "with_name", return_value=manifest), \
                    patch.object(download, "urlopen", return_value=io.BytesIO(fixture)) as fetch:
                download.download(target)
                fetch.assert_called_once_with(
                    "https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM/"
                    "resolve/837717ddb9ff5507820346191109dc79c958d614/pytorch_model.bin",
                    timeout=120)
                self.assertEqual(fixture, (target / "pytorch_model.bin").read_bytes())
            with patch.object(download.Path, "with_name", return_value=manifest), \
                    patch.object(download, "urlopen", return_value=io.BytesIO(b"tampered")), \
                    self.assertRaises(RuntimeError):
                download.download(root / "failed")
            self.assertFalse((root / "failed").exists())


class BenchmarkContractTest(unittest.TestCase):
    def test_operator_probe_covers_warmup_and_all_required_whole_clip_lengths(self):
        spec = importlib.util.spec_from_file_location("voice_benchmark", SERVICE / "benchmark.py")
        benchmark = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {"server": server}):
            spec.loader.exec_module(benchmark)
        with patch.object(sys, "argv", ["benchmark.py", "--model-dir", "/public-model"]), \
                patch.object(server, "profile", return_value=PROFILE), \
                patch.object(torch, "set_num_threads", create=True) as threads, \
                patch.object(torch, "set_num_interop_threads", create=True), \
                patch.object(server, "load_model") as loader, \
                patch.object(server, "embed", return_value=[1 / 16] * 256) as infer, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            benchmark.main()
        loader.assert_called_once_with("/public-model")
        threads.assert_called_once_with(2)
        rows = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([2, 30, 60, 120], [row["seconds"] for row in rows])
        self.assertEqual([2 * 16000, 30 * 16000, 60 * 16000, 120 * 16000],
                         [call.args[1].size for call in infer.call_args_list])
        self.assertTrue(all(row["dimensions"] == 256 and row["norm"] == 1 for row in rows))


class RealOfflineSmokeTest(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("VOICE_EMBEDDINGS_PUBLIC_TEST_MODEL_DIR"),
                         "opt-in: public checkpoint and pinned production dependencies required")
    def test_real_import_load_and_inference_without_network_or_credentials(self):
        script = """
import socket
attempts = []
def forbidden(*args, **kwargs):
    attempts.append("network")
    raise AssertionError("Network forbidden")
socket.socket.connect = forbidden
socket.socket.connect_ex = forbidden
socket.create_connection = forbidden
import sys
import server
from pyannote.audio.telemetry.metrics import is_metrics_enabled
assert not is_metrics_enabled()
server.profile()
server.torch.set_num_threads(2)
server.torch.set_num_interop_threads(1)
model = server.load_model(sys.argv[1])
for seconds in (.5, 2):
    samples = server.np.random.default_rng(0).normal(0, .1, int(seconds * 16000)).astype("float32")
    vector = server.embed(model, samples)
    assert len(vector) == 256
    assert abs(server.np.linalg.norm(vector) - 1) < 1e-12
assert attempts == [], attempts
print("offline smoke passed")
"""
        with tempfile.TemporaryDirectory() as home:
            # Deliberately do not inherit credentials or user configuration.
            environment = {"HOME": home, "HF_HOME": str(Path(home) / "hf"),
                           "PYTHONPATH": str(SERVICE), "OMP_NUM_THREADS": "2",
                           "MKL_NUM_THREADS": "2", "OPENBLAS_NUM_THREADS": "2"}
            result = subprocess.run(
                [sys.executable, "-c", script, os.environ["VOICE_EMBEDDINGS_PUBLIC_TEST_MODEL_DIR"]],
                env=environment, capture_output=True, text=True, timeout=120)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual("offline smoke passed", result.stdout.strip())


class HTTPContractTest(unittest.TestCase):
    def setUp(self):
        self.model = Mock(return_value=np.ones(256, dtype=np.float32))
        self.http = server.make_server(self.model, TOKEN, PROFILE, port=0)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join()

    def request(self, method="POST", path="/embed", body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.http.server_port, timeout=5)
        try:
            connection.request(method, path, body=body,
                               headers=headers if headers is not None else {"Authorization": f"Bearer {TOKEN}"})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), json.loads(response.read())
        finally:
            connection.close()

    def test_health_and_embedding_shapes_cache_control_and_no_logs(self):
        with contextlib.redirect_stderr(io.StringIO()) as logs:
            status, headers, payload = self.request("GET", "/health", headers={})
            self.assertEqual((200, {"ready": True, "profile": PROFILE, "dimensions": 256}), (status, payload))
            self.assertEqual("no-store", headers["Cache-Control"])
            status, headers, payload = self.request(body=make(.5))
            self.assertEqual(200, status)
            self.assertEqual({"embedding", "profile"}, set(payload))
            self.assertEqual(PROFILE, payload["profile"])
            self.assertEqual(256, len(payload["embedding"]))
            self.assertAlmostEqual(1, np.linalg.norm(payload["embedding"]))
            self.assertEqual("", logs.getvalue())

    def test_auth_and_routes(self):
        for headers in ({}, {"Authorization": "Bearer wrong"}):
            self.assertEqual((401, {"error": "Unauthorized"}),
                             self.request(body=make(.5), headers=headers)[::2])
        for method in ("GET", "POST"):
            self.assertEqual(404, self.request(method, "/unknown")[0])
        self.model.assert_not_called()

    def test_request_bounds_and_transfer_encoding(self):
        auth = {"Authorization": f"Bearer {TOKEN}"}
        for extra in ({"Content-Length": "invalid"}, {"Content-Length": "-1"},
                      {"Content-Length": str(server.MAX_BYTES + 1)}, {"Content-Length": "0"},
                      {"Transfer-Encoding": "chunked", "Content-Length": "5"}):
            self.assertEqual((400, {"error": "Invalid request"}),
                             self.request(body=b"", headers=auth | extra)[::2])
        self.model.assert_not_called()

    def test_invalid_audio_and_model_failures_are_generic_and_gate_recovers(self):
        for data in (b"garbage", make(.4), make(3, value=0), make(3)[:-1],
                     make(1, channels=2), make(1, rate=8000)):
            self.assertEqual((400, {"error": "Invalid audio"}), self.request(body=data)[::2])
        self.model.assert_not_called()
        self.model.side_effect = RuntimeError("must not leak model internals")
        self.assertEqual((400, {"error": "Invalid audio"}), self.request(body=make(.5))[::2])
        self.model.side_effect = None
        self.assertEqual(200, self.request(body=make(.5))[0])

    def test_inference_is_serialized(self):
        active = 0
        maximum = 0
        lock = threading.Lock()

        def infer(_):
            nonlocal active, maximum
            with lock:
                active += 1
                maximum = max(maximum, active)
            time.sleep(.05)
            with lock:
                active -= 1
            return np.ones(256)

        self.model.side_effect = infer
        results = []
        threads = [threading.Thread(target=lambda: results.append(self.request(body=make(.5))[0])) for _ in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual([200, 200], results)
        self.assertEqual(1, maximum)


if __name__ == "__main__":
    unittest.main()
