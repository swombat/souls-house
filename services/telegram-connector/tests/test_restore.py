"""A volume restored from an older copy, beyond Mira's two regressions: the
restored process queues events before it reaches Rails, so by the time it
checks the sequence its next number has passed Rails' again. The baseline
taken when the store was opened still shows the store is behind."""

import os
import shutil
import tempfile
import unittest

from connector.rails import Deliverer, Outcome
from connector.store import Crypto, Store
from tests.helpers import STORE_KEY, FakeRails


def message(n):
    return {"type": "message.upsert", "messages": [
        {"chat": "user:2001", "provider_message_id": str(n), "body": f"m{n}"}]}


class RestoreTest(unittest.IsolatedAsyncioTestCase):
    async def test_events_queued_before_the_check_are_renumbered_not_dropped(self):
        directory = tempfile.mkdtemp()
        path = os.path.join(directory, "store.sqlite3")
        rails = FakeRails()
        c = rails.connect("svc_1", "s" * 64, status="connected")

        store = Store(path, Crypto(STORE_KEY))
        store.ensure_connection("svc_1")
        store.set_callback_secret("svc_1", "s" * 64, 1)
        with store.transaction():
            store.enqueue("svc_1", message(1))
        self.assertEqual((Outcome.DONE, 1), await Deliverer(store, "svc_1", rails.post).run_once())
        store.db.close()
        shutil.copy(path, path + ".backup")  # the backup: next_seq 2

        store = Store(path, Crypto(STORE_KEY))
        with store.transaction():
            for n in range(2, 8):
                store.enqueue("svc_1", message(n))
        self.assertEqual(Outcome.DONE, (await Deliverer(store, "svc_1", rails.post).run_once())[0])
        store.db.close()
        self.assertEqual(7, c["committed"])

        shutil.copy(path + ".backup", path)  # the restore
        store = Store(path, Crypto(STORE_KEY))
        with store.transaction():  # sync runs before delivery reaches Rails
            for n in range(100, 110):
                store.enqueue("svc_1", message(n))
        self.assertEqual(12, store.connection("svc_1")["next_seq"], "past Rails' 7 already")
        outcome, _count = await Deliverer(store, "svc_1", rails.post).run_once()
        self.assertEqual(Outcome.DONE, outcome)
        self.assertEqual({str(n) for n in range(100, 110)} | {str(n) for n in range(1, 8)},
                         {mid for (_chat, mid) in c["messages"]})
        self.assertEqual(17, c["committed"])
        self.assertEqual(18, store.connection("svc_1")["next_seq"])
        store.db.close()

    async def test_a_reply_ahead_of_every_issued_number_is_never_taken_as_delivery(self):
        store = Store(os.path.join(tempfile.mkdtemp(), "s.sqlite3"), Crypto(STORE_KEY))
        rails = FakeRails()
        c = rails.connect("svc_1", "s" * 64, status="connected")
        store.ensure_connection("svc_1")
        store.set_callback_secret("svc_1", "s" * 64, 1)
        deliverer = Deliverer(store, "svc_1", rails.post)
        self.assertEqual(Outcome.DONE, (await deliverer.run_once())[0])  # checked: Rails at 0
        c["committed"] = 30  # Rails moved past this store while it was running
        with store.transaction():
            store.enqueue("svc_1", message(1))
        self.assertEqual(Outcome.FAILED, (await deliverer.run_once())[0])
        self.assertEqual(1, store.pending_count("svc_1"), "not marked delivered")
        self.assertEqual(Outcome.DONE, (await deliverer.run_once())[0])
        self.assertIn(("user:2001", "1"), c["messages"])
        self.assertEqual(31, c["committed"])
        store.db.close()


if __name__ == "__main__":
    unittest.main()
