"""The phone path's edges (PR 350 review): a sign-in Telegram accepted but
the connector could not finish ends cleanly instead of hanging; a first
code request that sends no code brings a live QR back; and the phone path's
deadline is the one both the timer and request_code go by."""

import asyncio
import unittest

from telethon import errors

from connector.fake import World
from tests.helpers import Harness, fast_settings, wait_for

PHONE = "+44 7700 900 123"
DIGITS = "447700900123"
CODE = "8642097531"


class PhoneLoginRecoveryTest(unittest.IsolatedAsyncioTestCase):
    async def asyncTearDown(self):
        await self.h.close()

    async def start(self, login_window=None, **world):
        world.setdefault("login_code", CODE)
        world.setdefault("phone", DIGITS)
        world.setdefault("auto_scan", None)
        settings = fast_settings(login_window=login_window) if login_window else None
        self.h = h = Harness(world=World(**world), settings=settings)
        h.rails.connect("svc_1", "s" * 64)
        status, reply = await self.command("start_login", generation=1, callback_secret="s" * 64,
                                           callback_secret_version=1)
        self.assertEqual(200, status, reply)
        await wait_for(lambda: h.world.qr_waiting.is_set())
        self.account = h.manager.account("svc_1")
        return h

    async def command(self, op, **fields):
        return await self.h.manager.command("svc_1", op, fields)

    def rails(self):
        return self.h.rails.connections["svc_1"]

    def qr_posts(self):
        return [event["code"] for event in self.h.rails.posts if event["type"] == "login.qr"]

    async def assert_failed_cleanly(self, code="failed"):
        await wait_for(lambda: self.rails()["login"].get("error") == code)
        self.assertEqual("failed", self.h.store.connection("svc_1")["status"])
        self.assertIsNone(self.h.store.connection("svc_1")["session"])
        self.assertIsNone(self.account.client)

    # -- finishing ---------------------------------------------------------------

    async def test_an_accepted_code_that_cannot_be_finished_fails_cleanly(self):
        h = await self.start()
        await self.command("request_code", generation=1, phone=PHONE)
        h.world.fail["get_state"] = [RuntimeError("transient")]
        self.assertEqual((200, {"outcome": "failed"}), await self.command("submit_code", generation=1, code=CODE))
        await self.assert_failed_cleanly()
        # The half-made session does not linger in Active Sessions.
        self.assertEqual(set(), h.world.sessions)
        self.assertEqual(1, h.world.logouts)
        self.assertEqual((409, {"error": "not_waiting_for_code"}),
                         await self.command("submit_code", generation=1, code=CODE))

    async def test_an_accepted_password_that_cannot_be_finished_fails_cleanly(self):
        h = await self.start(password="hunter2-RECOVERY")
        await self.command("request_code", generation=1, phone=PHONE)
        self.assertEqual((200, {"outcome": "password_required"}),
                         await self.command("submit_code", generation=1, code=CODE))
        # As through Rails: the password is asked for once the page shows the step.
        await wait_for(lambda: self.rails()["login"].get("step") == "password")
        h.world.fail["get_state"] = [RuntimeError("transient")]
        self.assertEqual((200, {"outcome": "failed"}),
                         await self.command("submit_password", generation=1, password="hunter2-RECOVERY"))
        await self.assert_failed_cleanly()
        self.assertEqual(set(), h.world.sessions)

    async def test_a_qr_sign_in_racing_the_code_request_that_cannot_be_finished_fails_cleanly(self):
        h = await self.start()
        # The QR was approved just as the number was sent.
        h.world.add_session(self.account.client.session)
        h.world.fail["get_state"] = [RuntimeError("transient")]
        self.assertEqual((200, {"outcome": "failed"}),
                         await self.command("request_code", generation=1, phone=PHONE))
        await self.assert_failed_cleanly()
        self.assertEqual(0, h.world.codes_sent)

    async def test_a_qr_sign_in_that_cannot_be_finished_fails_cleanly(self):
        h = await self.start()
        h.world.fail["get_state"] = [RuntimeError("transient")]
        h.world.scanned.set()
        await self.assert_failed_cleanly()

    # -- the QR comes back -----------------------------------------------------------

    async def assert_live_qr_after(self, reply):
        before = self.qr_posts()
        status, result = await self.command("request_code", generation=1, phone=PHONE)
        self.assertEqual((200, reply), (status, result))
        self.assertEqual("qr", self.account.login_phase)
        self.assertIsNone(self.account.phone_login)
        # A fresh code is posted, and scanning it signs in.
        await wait_for(lambda: len(self.qr_posts()) > len(before))
        self.assertNotIn(self.qr_posts()[-1], before)
        self.assertEqual(self.qr_posts()[-1], self.rails()["qr"])
        self.h.world.scanned.set()
        await wait_for(lambda: self.rails()["status"] == "connected")

    async def test_unsupported_delivery_brings_a_live_qr_back(self):
        h = await self.start()
        await wait_for(lambda: self.rails()["qr"] is not None)
        h.world.code_delivery = None
        await self.assert_live_qr_after({"outcome": "unsupported"})

    async def test_a_refused_first_request_brings_a_live_qr_back(self):
        h = await self.start()
        await wait_for(lambda: self.rails()["qr"] is not None)
        h.world.fail["send_code"] = [errors.PhoneNumberInvalidError(None)]
        await self.assert_live_qr_after({"outcome": "phone_invalid"})

    async def test_the_qr_that_comes_back_keeps_the_attempts_window(self):
        h = await self.start(login_window=0.5, qr_ttl=1)
        h.world.code_delivery = None
        await self.command("request_code", generation=1, phone=PHONE)
        await wait_for(lambda: self.rails()["login"].get("error") == "expired", timeout=5)
        self.assertEqual("failed", h.store.connection("svc_1")["status"])

    async def test_a_resend_telegram_cannot_deliver_keeps_the_code_already_sent(self):
        h = await self.start()
        self.assertEqual("code_sent", (await self.command("request_code", generation=1, phone=PHONE))[1]["outcome"])
        qr_posts = len(self.qr_posts())
        h.world.code_delivery = None
        self.assertEqual((200, {"outcome": "unsupported"}),
                         await self.command("request_code", generation=1, phone=PHONE))
        self.assertEqual("code", self.account.login_phase)
        await asyncio.sleep(0.2)
        self.assertEqual(qr_posts, len(self.qr_posts()), "no QR for an attempt on the phone path")
        self.assertEqual((200, {"outcome": "accepted"}), await self.command("submit_code", generation=1, code=CODE))
        await wait_for(lambda: self.rails()["status"] == "connected")

    # -- one deadline ------------------------------------------------------------------

    async def test_a_request_after_the_phone_deadline_expires_instead_of_sending(self):
        h = await self.start()
        await self.command("request_code", generation=1, phone=PHONE)
        # The timer is due but has not had the lock yet.
        self.account.code_deadline = asyncio.get_running_loop().time() - 1
        self.assertEqual((200, {"outcome": "expired"}),
                         await self.command("request_code", generation=1, phone=PHONE))
        self.assertEqual(1, h.world.codes_sent)
        await self.assert_failed_cleanly("expired")
        expiries = [e for e in h.rails.posts if e["type"] == "login.failed"]
        self.assertEqual(1, len(expiries), "expired once, not again by the timer")


if __name__ == "__main__":
    unittest.main()
