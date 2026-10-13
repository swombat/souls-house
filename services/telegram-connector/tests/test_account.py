import asyncio
import unittest

from telethon import errors

from connector.fake import ALICE, BIG, BOT, FAMILY, NEWS, SELF_ID, TEAM, World
from tests.helpers import Harness, fast_settings, settle, wait_for


class ConnectAndSyncTest(unittest.IsolatedAsyncioTestCase):
    async def asyncTearDown(self):
        await self.h.close()

    async def test_qr_login_then_backfill_scope_and_live_messages(self):
        self.h = h = Harness()
        account = await h.connect()
        rails = h.rails.connections["svc_1"]
        self.assertEqual({"user_id": str(SELF_ID), "display_name": "Daniel", "username": "daniel"}, rails["identity"])
        await settle(account)

        chats = rails["chats"]
        self.assertEqual({f"user:{ALICE}", f"user:{BOT}", f"user:{SELF_ID}", f"chat:{FAMILY}", f"channel:{TEAM}",
                          f"channel:{NEWS}", f"channel:{BIG}"}, set(chats))
        self.assertEqual({"synced": False, "reason": "bot"}, {k: v for k, v in chats[f"user:{BOT}"]["sync_state"].items()})
        self.assertEqual("broadcast_channel", chats[f"channel:{NEWS}"]["sync_state"]["reason"])
        self.assertEqual("large_group", chats[f"channel:{BIG}"]["sync_state"]["reason"])
        self.assertTrue(chats[f"channel:{TEAM}"]["sync_state"]["synced"])
        self.assertEqual("saved", chats[f"user:{SELF_ID}"]["kind"])

        # The last 30 days of history (one message a day; the one exactly 30
        # days before the world began is just outside), not 40.
        alice = h.rails.bodies("svc_1", f"user:{ALICE}")
        self.assertEqual(29, sum(1 for body in alice.values() if body and body.startswith("old ")))
        photo = [m for (chat, _), m in rails["messages"].items() if m.get("media_kind") == "photo"]
        self.assertEqual("a photo caption", photo[0]["caption"])
        self.assertIn("history_from", chats[f"user:{ALICE}"]["sync_state"])
        self.assertEqual(29, sum(1 for (chat, _) in rails["messages"] if chat == f"channel:{TEAM}"))

        # Live: new messages keep arriving, through our own getDifference.
        for n in range(3):
            h.world.add_message(f"user:{ALICE}", f"hello {n}")
        h.world.add_message(f"channel:{TEAM}", "team live")
        await wait_for(lambda: {"hello 0", "hello 1", "hello 2"} <= set(h.rails.bodies("svc_1", f"user:{ALICE}").values()))
        await wait_for(lambda: "team live" in h.rails.bodies("svc_1", f"channel:{TEAM}").values())
        # Unsynced chats never get messages.
        self.assertFalse(any(chat in (f"channel:{BIG}", f"channel:{NEWS}", f"user:{BOT}") for chat, _ in rails["messages"]))
        await wait_for(lambda: f"user:{ALICE}" in rails["checkpoints"])

    async def test_edits_and_deletes_resolve_through_the_peer_map(self):
        self.h = h = Harness()
        account = await h.connect()
        await settle(account)
        message = h.world.add_message(f"chat:{FAMILY}", "to be edited")
        await wait_for(lambda: "to be edited" in h.rails.bodies("svc_1", f"chat:{FAMILY}").values())
        h.world.edit_message(message, "edited")
        await wait_for(lambda: h.rails.bodies("svc_1", f"chat:{FAMILY}")[str(message.id)] == "edited")
        # A restart in between: the peer map is durable.
        await h.restart()
        h.world.delete_messages([message.id, 999_999])
        connection = h.rails.connections["svc_1"]
        await wait_for(lambda: connection["messages"][(f"chat:{FAMILY}", str(message.id))].get("deleted"))
        self.assertEqual(1, connection["unresolved"], "an id the connector never saw is counted, not guessed")

    async def test_logout_logs_out_at_telegram_and_deletes_the_store(self):
        self.h = h = Harness()
        account = await h.connect()
        await settle(account)
        status, reply = await h.manager.command("svc_1", "logout", {})
        self.assertEqual((200, {"status": "logged_out"}), (status, reply))
        self.assertEqual(1, h.world.logouts)
        self.assertEqual(set(), h.world.sessions)
        self.assertIsNone(h.store.connection("svc_1"))
        self.assertEqual(0, h.store.db.execute("SELECT COUNT(*) FROM outbox").fetchone()[0])
        self.assertEqual(0, h.store.db.execute("SELECT COUNT(*) FROM chats").fetchone()[0])

    async def test_a_session_ended_from_the_phone_is_reported_logged_out(self):
        self.h = h = Harness()
        account = await h.connect()
        await settle(account)
        h.world.revoked = True
        h.world.add_message(f"user:{ALICE}", "after revoke")
        await wait_for(lambda: h.rails.connections["svc_1"]["status"] == "reauthorizing")
        self.assertIsNone(h.store.session("svc_1"))

    async def test_rails_410_revokes_and_deletes(self):
        self.h = h = Harness()
        account = await h.connect()
        await settle(account)
        h.rails.connections["svc_1"]["revoked"] = True
        h.world.add_message(f"user:{ALICE}", "after disconnect")
        await wait_for(lambda: h.store.connection("svc_1") is None)
        self.assertEqual(1, h.world.logouts)

    async def test_search_synced_scope(self):
        self.h = h = Harness()
        account = await h.connect()
        await settle(account)
        h.world.add_message(f"user:{ALICE}", "lunch tomorrow?")
        status, reply = await h.manager.command("svc_1", "search", {"query": "lunch", "limit": 5, "scope": "synced"})
        self.assertEqual(200, status)
        self.assertEqual(["lunch tomorrow?"], [r["body"] for r in reply["results"]])
        self.assertEqual("synced", reply["coverage"]["scope"])
        status, reply = await h.manager.command("svc_1", "search", {"query": "x", "chat": f"channel:{BIG}", "scope": "synced"})
        self.assertEqual((403, {"error": "chat_not_synced"}), (status, reply))


class LoginTest(unittest.IsolatedAsyncioTestCase):
    async def asyncTearDown(self):
        await self.h.close()

    async def start(self, h, generation=1):
        h.rails.connect("svc_1", "s" * 64) if "svc_1" not in h.rails.connections else None
        return await h.manager.command("svc_1", "start_login", {
            "generation": generation, "callback_secret": "s" * 64, "callback_secret_version": 1})

    async def test_qr_is_posted_with_generation_and_renewed_until_the_window_ends(self):
        self.h = h = Harness(world=World(qr_ttl=1), settings=fast_settings(login_window=2.5))
        await self.start(h)
        await wait_for(lambda: h.world.qr_issued >= 2, timeout=5)
        qrs = [e for e in h.rails.posts if e["type"] == "login.qr"]
        self.assertTrue(all(e["generation"] == 1 and "seq" not in e for e in qrs))
        self.assertTrue(qrs[0]["code"].startswith("tg://login?token="))
        await wait_for(lambda: h.rails.connections["svc_1"]["login"].get("error") == "expired", timeout=6)

    async def test_two_step_password_wrong_then_right(self):
        self.h = h = Harness(world=World(password="hunter2-CANARY"))
        await self.start(h)
        await wait_for(lambda: h.world.qr_waiting.is_set())
        h.world.scanned.set()
        await wait_for(lambda: h.rails.connections["svc_1"]["login"].get("step") == "password")
        self.assertEqual("the usual", h.rails.connections["svc_1"]["login"]["hint"])
        status, reply = await h.manager.command("svc_1", "submit_password", {"generation": 1, "password": "nope"})
        self.assertEqual((200, {"outcome": "password_invalid"}), (status, reply))
        status, reply = await h.manager.command("svc_1", "submit_password", {"generation": 2, "password": "hunter2-CANARY"})
        self.assertEqual((409, {"error": "not_waiting_for_password"}), (status, reply))
        fields = {"generation": 1, "password": "hunter2-CANARY"}
        status, reply = await h.manager.command("svc_1", "submit_password", fields)
        self.assertEqual((200, {"outcome": "accepted"}), (status, reply))
        self.assertNotIn("password", fields, "the password is taken out of the command fields")
        await wait_for(lambda: h.rails.connections["svc_1"]["status"] == "connected")
        dump = "\n".join(h.store.db.iterdump())
        self.assertNotIn("hunter2-CANARY", dump)
        with open(h.path, "rb") as handle:
            self.assertNotIn(b"CANARY", handle.read())

    async def test_flood_wait_during_login(self):
        self.h = h = Harness()
        h.world.fail["begin_qr"] = [errors.FloodWaitError(None, capture=42)]
        await self.start(h)
        await wait_for(lambda: h.rails.connections["svc_1"]["login"].get("error") == "flood_wait")
        self.assertEqual(42, h.rails.connections["svc_1"]["login"]["retry_after"])

    async def test_cancel_mid_qr_and_stale_generations(self):
        self.h = h = Harness()
        await self.start(h)
        await wait_for(lambda: h.world.qr_waiting.is_set())
        invalidated = h.rails.cancel_login("svc_1")
        status, reply = await h.manager.command("svc_1", "cancel_login", {"generation": invalidated})
        self.assertEqual((200, {"status": "cancelled"}), (status, reply))
        self.assertNotIn("login", h.manager.account("svc_1").tasks)
        # A delayed or replayed start for the cancelled generation cannot reopen it.
        status, reply = await self.start(h, generation=1)
        self.assertEqual((409, {"error": "stale_generation"}), (status, reply))
        # Restart: generation 3 logs in.
        generation = h.rails.begin_login("svc_1")
        status, _ = await self.start(h, generation=generation)
        self.assertEqual(200, status)
        h.world.qr_waiting.clear()
        await wait_for(lambda: h.world.qr_waiting.is_set())
        h.world.scanned.set()
        await wait_for(lambda: h.rails.connections["svc_1"]["status"] == "connected")
        self.assertEqual(3, h.rails.connections["svc_1"]["generation"])

    async def test_a_lower_secret_version_is_refused(self):
        self.h = h = Harness()
        h.rails.connect("svc_1", "s" * 64)
        await h.manager.command("svc_1", "start_login", {"generation": 1, "callback_secret": "s" * 64,
                                                         "callback_secret_version": 2})
        status, reply = await h.manager.command("svc_1", "start_login", {"generation": 2, "callback_secret": "t" * 64,
                                                                         "callback_secret_version": 1})
        self.assertEqual((409, {"error": "stale_secret_version"}), (status, reply))


if __name__ == "__main__":
    unittest.main()
