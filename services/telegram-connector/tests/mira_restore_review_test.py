import unittest

from connector.rails import Deliverer, Outcome
from tests.helpers import Harness


class RestoreReviewTest(unittest.IsolatedAsyncioTestCase):
    async def test_restored_known_sequence_does_not_discard_new_messages(self):
        h = Harness()
        try:
            c = h.rails.connect("svc_1", "s" * 64, status="connected")
            h.store.ensure_connection("svc_1")
            h.store.set_callback_secret("svc_1", "s" * 64, 1)
            h.store.update_connection("svc_1", seq_known=1, next_seq=5, generation=1)
            # A restored volume is behind the Rails database.
            c["committed"] = 10
            h.store.enqueue("svc_1", {"type": "message.upsert", "messages": [
                {"chat": "user:2001", "provider_message_id": "999", "body": "new after restore"}]})
            result, count = await Deliverer(h.store, "svc_1", h.rails.post).run_once()
            self.assertEqual(Outcome.DONE, result)
            self.assertEqual(0, h.store.pending_count("svc_1"))
            self.assertIn(("user:2001", "999"), c["messages"],
                          "a new event was acknowledged and deleted without being applied")
        finally:
            await h.close()

    async def test_sign_in_again_reconciles_restored_sequence(self):
        h = Harness()
        try:
            c = h.rails.connect("svc_1", "s" * 64, generation=2)
            h.store.ensure_connection("svc_1")
            h.store.set_callback_secret("svc_1", "s" * 64, 1)
            h.store.update_connection("svc_1", seq_known=1, next_seq=5, generation=1)
            c["committed"] = 10
            account = h.manager.account("svc_1", create=True)
            await account.start_login(2, "s" * 64, 1)
            # Stop background work; simulate successful current-generation login.
            await account._cancel(*list(account.tasks))
            h.store.enqueue("svc_1", {"type": "status.changed", "status": "connected",
                                    "generation": 2, "identity": {"user_id": "1000"}})
            await account.deliverer.run_once()
            self.assertEqual("connected", c["status"],
                             "the new login completion is also discarded below Rails' sequence")
        finally:
            await h.close()
