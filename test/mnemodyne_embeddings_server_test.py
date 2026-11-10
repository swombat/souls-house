"""Embedding server gate under a wake burst (#804); synthetic model, no weights."""
import importlib.util
import json
from pathlib import Path
import threading
import time
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "mnemodyne_embeddings_server", ROOT / "services/mnemodyne-embeddings/server.py")
server_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server_module)

TOKEN = "synthetic-token-" + "x" * 16


class SlowModel:
    """Holds the inference slot for a fixed time per call, like a real embed."""

    def __init__(self, seconds):
        self.seconds = seconds
        self.lock = threading.Lock()
        self.active = 0
        self.max_active = 0

    def embed(self, texts):
        with self.lock:
            self.active += 1
            self.max_active = max(self.max_active, self.active)
        try:
            time.sleep(self.seconds)
            for _ in texts:
                yield _Vector()
        finally:
            with self.lock:
                self.active -= 1


class _Vector:
    def tolist(self):
        return [0.1, 0.2, 0.3]


class EmbeddingsServerGateTest(unittest.TestCase):
    def start(self, model, gate_wait=server_module.GATE_WAIT_SECONDS):
        server = server_module.build_server(model, TOKEN, "127.0.0.1", 0, gate_wait=gate_wait)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}/v1/embeddings"

    def post(self, url):
        body = json.dumps({"input": "Synthetic recall", "model": server_module.PROFILE}).encode()
        request = urllib.request.Request(url, data=body, method="POST", headers={
            "Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
        started = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                status = response.status
        except urllib.error.HTTPError as error:
            status = error.code
        return status, time.monotonic() - started

    def burst(self, url, count):
        results = [None] * count
        def run(index):
            results[index] = self.post(url)
        threads = [threading.Thread(target=run, args=(i,)) for i in range(count)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        return results

    def test_waiter_is_served_when_the_first_inference_outlasts_the_old_half_second(self):
        model = SlowModel(0.8)
        url = self.start(model)
        results = self.burst(url, 2)
        self.assertEqual([200, 200], [status for status, _ in results])
        self.assertEqual(1, model.max_active)

    def test_old_half_second_gate_bounced_the_same_waiter(self):
        url = self.start(SlowModel(0.8), gate_wait=0.5)
        self.assertEqual([200, 503], sorted(status for status, _ in self.burst(url, 2)))

    def test_six_at_once_queue_one_at_a_time_and_report_elapsed(self):
        # 0.2 s per embed is a pessimistic stand-in; this measures the queue,
        # not bge-small's real speed on the box.
        model = SlowModel(0.2)
        url = self.start(model)
        results = self.burst(url, 6)
        elapsed = sorted(round(seconds, 2) for _, seconds in results)
        print(f"\nsix-request burst, 0.2 s synthetic embed, elapsed: {elapsed}")
        self.assertEqual([200] * 6, [status for status, _ in results])
        self.assertEqual(1, model.max_active)
        self.assertLess(max(elapsed), 2.0)

    def test_a_waiter_past_the_gate_wait_gets_503_not_a_dropped_connection(self):
        url = self.start(SlowModel(1.0), gate_wait=0.2)
        self.assertEqual([200, 503], sorted(status for status, _ in self.burst(url, 2)))


if __name__ == "__main__":
    unittest.main()
