"""Offline PR342 review regressions; expected to fail at 71b4df3d."""

import asyncio
import json
import unittest

from connector.fake import ALICE, BOB
from connector.telegram import Dialog
from tests.helpers import Harness, fast_settings, settle, wait_for


class StopIterationProbe(BaseException):
    pass


class SyncReviewTest(unittest.IsolatedAsyncioTestCase):
    async def asyncTearDown(self):
        await self.h.close()

    async def test_live_discovered_chat_wakes_history_worker(self):
        self.h = h = Harness(settings=fast_settings())
        account = await h.connect()
        await settle(account)
        await asyncio.sleep(0.1)
        old = h.world._message(f"user:{BOB}", "prior Bob history", h.world.t0)
        h.world.history_seed.append(old)
        h.world.add_message(f"user:{BOB}", "first Bob live")
        await wait_for(lambda: "first Bob live" in h.rails.bodies("svc_1", f"user:{BOB}").values())
        await asyncio.sleep(0.3)
        # A periodic dialog refresh also does not wake it once the live
        # difference already recorded this chat's scope.
        original_dialogs = account.client.dialogs

        async def dialogs_with_bob():
            return await original_dialogs() + [Dialog(h.world.users[BOB], h.world.t0)]

        account.client.dialogs = dialogs_with_bob
        await account._refresh_dialogs(force=False)
        await asyncio.sleep(0.1)
        before_wake = list(h.rails.bodies("svc_1", f"user:{BOB}").values())
        account.backfill_wake.set()
        await settle(account)
        self.assertIn("prior Bob history", h.rails.bodies("svc_1", f"user:{BOB}").values(),
                      "control: the provider has the history and a wake imports it")
        self.assertIn("prior Bob history", before_wake)

    async def test_saturated_difference_does_not_emit_ahead_checkpoint(self):
        self.h = h = Harness(settings=fast_settings())
        account = await h.connect()
        await settle(account)
        await account._cancel("sync", "backfill", "delivery")
        h.world.slice_size = 1
        account.settings.outbox_cap = 1
        account.settings.checkpoint_interval = 0
        account.settings.channel_poll_interval = 3600
        async def already_refreshed(force):
            pass
        account._refresh_dialogs = already_refreshed
        for n in range(3):
            h.world.add_message(f"user:{ALICE}", f"undrained {n}")

        # Observe one actual _sync_loop iteration, stopping after its
        # checkpoint, before the next iteration waits for capacity.
        original_checkpoint = account._checkpoint

        def checkpoint(through):
            original_checkpoint(through)
            raise StopIterationProbe()

        account._checkpoint = checkpoint
        with self.assertRaises(StopIterationProbe):
            await account._sync_loop()
        self.assertLess(h.store.connection("svc_1")["pts"], h.world.visible_pts())
        self.assertEqual(1, h.store.connection("svc_1")["pts"])
        self.assertEqual(3, h.world.visible_pts())
        checkpoints = [
            json.loads(row["body"])
            for row in h.store.pending("svc_1")
            if json.loads(row["body"])["type"] == "sync.checkpoint"
        ]
        self.assertEqual([], checkpoints, "incomplete DifferenceSlice must not publish synced_through")

    async def test_in_flight_history_page_cannot_overwrite_gap_reset(self):
        self.h = h = Harness(settings=fast_settings(backfill_page=5))
        account = await h.connect()
        await settle(account)
        await account._cancel("sync", "backfill", "delivery")
        key = f"user:{ALICE}"
        page = h.world.history(key, None, 5)
        old_offset = min(m.id for m in page)
        h.store.set_backfill("svc_1", key, old_offset, 5, False)
        fetched, release = asyncio.Event(), asyncio.Event()
        original_history = account.client.history

        async def delayed_history(*args):
            result = await original_history(*args)
            fetched.set()
            await release.wait()
            return result

        account.client.history = delayed_history
        task = asyncio.create_task(account.backfill_page(key))
        await fetched.wait()
        h.world.add_message(key, "new history in unreplayable gap")
        h.world.too_long_below = 1
        await account.account_difference()
        self.assertIsNone(h.store.chat("svc_1", key)["backfill_offset"],
                          "control: DifferenceTooLong did reset history to its newest page")
        release.set()
        await task
        stale_offset = h.store.chat("svc_1", key)["backfill_offset"]
        while not h.store.chat("svc_1", key)["backfill_done"]:
            await account.backfill_page(key)
        await account.deliverer.run_once()
        self.assertIn("new history in unreplayable gap", h.rails.bodies("svc_1", key).values(),
                      f"stale cursor {stale_offset} overwrote gap reset; completed backfill skipped gap content")


if __name__ == "__main__":
    unittest.main()
