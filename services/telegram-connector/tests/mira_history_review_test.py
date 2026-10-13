import datetime
import unittest

from connector.fake import ALICE, now
from tests.helpers import Harness, fast_settings, settle


class HistoryReviewTest(unittest.IsolatedAsyncioTestCase):
    async def test_count_capped_history_does_not_claim_the_entire_time_window(self):
        h = Harness(settings=fast_settings(backfill_max=2, backfill_page=2))
        try:
            # Fill the two-row cap with today's messages; old history exists.
            h.world.add_message(f"user:{ALICE}", "recent 1")
            h.world.add_message(f"user:{ALICE}", "recent 2")
            account = await h.connect()
            await settle(account)
            chat = h.store.chat("svc_1", f"user:{ALICE}")
            history_from = datetime.datetime.fromisoformat(chat["history_from"].replace("Z", "+00:00"))
            self.assertGreater(history_from, now() - datetime.timedelta(days=1),
                               "hitting the count cap must not report coverage back to 30 days")
        finally:
            await h.close()
