"""Outbox-before-progress, for live updates and backfill (Mira's S2a
boundary 2): a crash at any point of the ingest path, a Rails outage, a lost
acknowledgement or a saturated outbox loses nothing."""

import asyncio
import datetime
import unittest

from telethon import errors
from telethon._updates import MessageBox, SessionState
from telethon.tl import types

from connector.fake import ALICE, FAMILY, TEAM, World
from connector.telegram import HouseSession
from tests.helpers import Harness, fast_settings, settle, wait_for


class Crash(BaseException):
    """Stands for the process dying: nothing in the connector catches it."""


def crash_at(store, point, times=1):
    state = {"left": times}

    def fault(name):
        if name == point and state["left"] > 0:
            state["left"] -= 1
            raise Crash(point)
    store.fault = fault
    return state


class ReplayTest(unittest.IsolatedAsyncioTestCase):
    async def asyncTearDown(self):
        await self.h.close()

    async def connected(self, **settings):
        self.h = Harness(settings=fast_settings(**settings))
        account = await self.h.connect()
        await settle(account)
        return account

    def live_bodies(self):
        return {b for b in self.h.rails.bodies("svc_1", f"user:{ALICE}").values() if b and b.startswith("live")}

    async def test_crash_between_outbox_write_and_state_replays_live_updates(self):
        account = await self.connected()
        h = self.h
        pts_before = h.store.connection("svc_1")["pts"]
        crash_at(h.store, "live:after_outbox")
        for n in range(5):
            h.world.add_message(f"user:{ALICE}", f"live {n}")
        await wait_for(lambda: "sync" not in account.tasks)  # the sync task died mid-transaction
        self.assertEqual(pts_before, h.store.connection("svc_1")["pts"], "state did not move")
        self.assertEqual(set(), self.live_bodies(), "nothing was committed")
        await h.restart()
        await wait_for(lambda: self.live_bodies() == {f"live {n}" for n in range(5)})
        self.assertEqual(h.world.visible_pts(), h.store.connection("svc_1")["pts"])

    async def test_crash_after_commit_before_delivery(self):
        account = await self.connected()
        h = self.h
        h.rails.down = True
        crash_at(h.store, "live:after_commit")
        for n in range(3):
            h.world.add_message(f"user:{ALICE}", f"live {n}")
        await wait_for(lambda: "sync" not in account.tasks)
        self.assertGreater(h.store.pending_count("svc_1"), 0, "the events are in the outbox, undelivered")
        await h.restart()
        h.rails.down = False
        await wait_for(lambda: self.live_bodies() == {"live 0", "live 1", "live 2"})

    async def test_rails_commits_but_the_acknowledgement_is_lost(self):
        await self.connected()
        h = self.h
        committed = h.rails.connections["svc_1"]["committed"]
        h.rails.drop_ack = 1
        h.world.add_message(f"user:{ALICE}", "live once")
        h.world.add_message(f"user:{ALICE}", "live twice")
        await wait_for(lambda: self.live_bodies() == {"live once", "live twice"})
        await wait_for(lambda: h.store.pending_count("svc_1") == 0)
        applied = h.rails.connections["svc_1"]["applied"]
        self.assertEqual(h.rails.connections["svc_1"]["committed"], h.store.connection("svc_1")["next_seq"] - 1)
        self.assertGreater(h.rails.connections["svc_1"]["committed"], committed)
        self.assertEqual(len(applied), len(set(range(len(applied)))))  # sanity

    async def test_crash_in_backfill_resumes_from_the_cursor(self):
        self.h = h = Harness(settings=fast_settings(backfill_page=10))
        state = crash_at(h.store, "backfill:after_outbox", times=1)
        await h.connect()
        await wait_for(lambda: state["left"] == 0)
        await h.restart()
        account = h.manager.account("svc_1")
        await settle(account)
        alice = h.rails.bodies("svc_1", f"user:{ALICE}")
        self.assertEqual(29, sum(1 for body in alice.values() if body and body.startswith("old ")))
        self.assertEqual(29, sum(1 for chat, _ in h.rails.connections["svc_1"]["messages"] if chat == f"channel:{TEAM}"))

    async def test_restart_between_backfill_pages_does_not_refetch_committed_pages(self):
        self.h = h = Harness(settings=fast_settings(backfill_page=10, backfill_pause=0.2))
        await h.connect()
        await wait_for(lambda: (h.store.chat("svc_1", f"user:{ALICE}") or {"backfill_count": 0})["backfill_count"] >= 10)
        await h.restart()
        cursor = h.store.chat("svc_1", f"user:{ALICE}")["backfill_offset"]
        h.world.requests.clear()
        await settle(h.manager.account("svc_1"))
        first = [r for r in h.world.requests if r[0] == "history" and r[1] == f"user:{ALICE}"][0]
        self.assertEqual(cursor, first[2], "backfill resumed from its committed cursor")

    async def test_saturation_stops_ingestion_and_resumes_without_loss(self):
        account = await self.connected(outbox_cap=4, outbox_low=2)
        h = self.h
        h.world.slice_size = 1  # one event per update, to fill the outbox fast
        h.rails.refuse_types["message.upsert"] = 503
        for n in range(12):
            h.world.add_message(f"user:{ALICE}", f"live {n}")
        await wait_for(lambda: h.rails.connections["svc_1"]["availability"] == "backlogged")
        await asyncio.sleep(0.3)
        pending = h.store.pending_count("svc_1")
        self.assertLessEqual(pending, 4, "ingestion stopped at the cap")
        self.assertLess(h.store.connection("svc_1")["pts"], h.world.visible_pts(), "state did not run ahead of the outbox")
        # A restart while saturated loses nothing either.
        await h.restart()
        account = h.manager.account("svc_1")
        await asyncio.sleep(0.2)
        self.assertLessEqual(h.store.pending_count("svc_1"), 4)
        del h.rails.refuse_types["message.upsert"]
        await wait_for(lambda: self.live_bodies() == {f"live {n}" for n in range(12)}, timeout=10)
        await wait_for(lambda: h.rails.connections["svc_1"]["availability"] == "ok")

    async def test_a_poison_event_is_replaced_by_a_no_op_after_five_refusals(self):
        await self.connected()
        h = self.h
        h.rails.refuse_types["message.upsert"] = 422
        before = len(h.rails.posts)
        h.world.add_message(f"user:{ALICE}", "live poison")
        await wait_for(lambda: sum(1 for e in h.rails.posts[before:] if e["type"] == "message.upsert") >= 5)
        del h.rails.refuse_types["message.upsert"]
        h.world.add_message(f"chat:{FAMILY}", "after the poison")
        await wait_for(lambda: "after the poison" in h.rails.bodies("svc_1", f"chat:{FAMILY}").values())
        self.assertNotIn("live poison", self.live_bodies())


class BackfillDoesNotStarveTest(unittest.IsolatedAsyncioTestCase):
    async def asyncTearDown(self):
        await self.h.close()

    async def test_account_flood_wait_in_backfill_leaves_live_search_login_and_logout_working(self):
        self.h = h = Harness(settings=fast_settings(backfill_page=5))
        h.world.fail["history"] = [None, errors.FloodWaitError(None, capture=3600)]
        account = await h.connect()
        await wait_for(lambda: account.flood_until > 0)
        # Live sync still runs.
        h.world.add_message(f"user:{ALICE}", "live while backfill waits")
        await wait_for(lambda: "live while backfill waits" in h.rails.bodies("svc_1", f"user:{ALICE}").values(), timeout=2)
        # Search answers at once.
        status, reply = await asyncio.wait_for(
            h.manager.command("svc_1", "search", {"query": "while backfill", "scope": "synced"}), 1)
        self.assertEqual(200, status)
        # Another account can log in meanwhile.
        h.rails.connect("svc_2", "t" * 64)
        h.world.qr_waiting.clear()
        status, _ = await asyncio.wait_for(h.manager.command("svc_2", "start_login", {
            "generation": 1, "callback_secret": "t" * 64, "callback_secret_version": 1}), 1)
        self.assertEqual(200, status)
        await wait_for(lambda: h.world.qr_waiting.is_set())
        # Backfill is still paused, not retried in a loop.
        history_calls = [r for r in h.world.requests if r[0] == "history"]
        await asyncio.sleep(0.3)
        self.assertEqual(len(history_calls), len([r for r in h.world.requests if r[0] == "history"]))
        status, _ = await asyncio.wait_for(h.manager.command("svc_1", "logout", {}), 2)
        self.assertEqual(200, status)


class TelethonStateTest(unittest.IsolatedAsyncioTestCase):
    """What the connector found about Telethon 1.41.2's own update state."""

    async def test_telethon_message_box_advances_before_any_handler_runs(self):
        box = MessageBox(__import__("logging").getLogger("test"))
        box.load(SessionState(0, 0, 0, pts=10, qts=0, date=int(datetime.datetime.now().timestamp()), seq=1, takeout_id=None), [])
        message = types.Message(id=1, peer_id=types.PeerUser(5), date=datetime.datetime.now(datetime.timezone.utc), message="x")
        update = types.UpdateShortMessage(id=1, user_id=5, message="x", pts=11, pts_count=1,
                                          date=datetime.datetime.now(datetime.timezone.utc))
        processed = []

        class Cache:
            self_id = 1
            def get(self, _): return None
            def extend(self, *_): pass
        box.process_updates(update, Cache(), processed)
        state, _channels = box.session_state()
        # The state Telethon would save at its next keepalive already covers
        # pts 11, though no event handler has seen the message yet.
        self.assertEqual(11, state["pts"])
        self.assertEqual(1, len(processed))
        del message

    def test_house_session_persists_no_update_state(self):
        session = HouseSession()
        session.set_update_state(0, types.updates.State(pts=99, qts=0, date=datetime.datetime.now(), seq=0, unread_count=0))
        self.assertEqual([], list(session.get_update_states()))
        self.assertIsNone(session.get_update_state(0))


if __name__ == "__main__":
    unittest.main()
