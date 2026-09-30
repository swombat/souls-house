"""No resident, provider or outbound HTTP calls."""
import importlib.util
from pathlib import Path
import tempfile
import threading
import time
import unittest
import uuid

spec = importlib.util.spec_from_file_location("async_turns", Path(__file__).parents[1] / "agent-runtime/async_turns.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class TurnStoreTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.release = threading.Event()
        self.calls = []

        def execute(payload, cancel):
            self.calls.append(payload)
            self.release.wait(3)
            return {"status": 200, "body": {"status": "ok"}}

        self.store = module.TurnStore(self.directory.name, execute)
        self.turn = str(uuid.uuid4())
        self.payload = {"session_id": "synthetic", "request": "synthetic prompt"}

    def tearDown(self):
        self.release.set()
        for _ in range(100):
            if not self.store.cancellations:
                break
            time.sleep(.01)
        self.store.owner.close()
        self.directory.cleanup()

    def test_duplicate_delivery_is_one_execution(self):
        threads = [threading.Thread(target=self.store.submit, args=(self.turn, self.payload)) for _ in range(20)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(1, len(self.calls))
        with self.assertRaises(module.Conflict):
            self.store.submit(self.turn, {**self.payload, "request": "different"})
        with self.assertRaises(module.Conflict):
            self.store.submit(str(uuid.uuid4()), self.payload)

    def test_cancellation_keeps_reservation_until_executor_returns(self):
        self.store.submit(self.turn, self.payload)
        self.store.cancel(self.turn)
        self.assertIn(self.store.status(self.turn)["state"], ("accepted", "running"))
        with self.assertRaises(module.Conflict):
            self.store.submit(str(uuid.uuid4()), self.payload)
        self.release.set()
        for _ in range(100):
            if self.store.status(self.turn)["state"] == "cancelled":
                break
            time.sleep(.01)
        self.assertEqual("cancelled", self.store.status(self.turn)["state"])

    def test_restart_never_replays_uncertain_acceptance(self):
        with self.store.connect() as db:
            db.execute("INSERT INTO turns VALUES (?, 'digest', 'synthetic', 'accepted', 0, NULL)", (self.turn,))
        self.store.owner.close()
        self.store = module.TurnStore(self.directory.name, lambda *args: self.fail("must not execute"))
        self.assertEqual("unknown", self.store.status(self.turn)["state"])
        with self.assertRaises(module.Conflict):
            self.store.submit(str(uuid.uuid4()), self.payload)

    def test_second_owner_fails_closed(self):
        with self.assertRaises(BlockingIOError):
            module.TurnStore(self.directory.name, lambda *args: None)

    def test_exception_does_not_claim_execution_stopped(self):
        self.store.execute = lambda *args: (_ for _ in ()).throw(RuntimeError("private"))
        self.store.submit(self.turn, self.payload)
        for _ in range(100):
            if self.store.status(self.turn)["state"] == "unknown":
                break
            time.sleep(.01)
        self.assertEqual("unknown", self.store.status(self.turn)["state"])
        self.assertNotIn("private", str(self.store.status(self.turn)))


if __name__ == "__main__":
    unittest.main()
