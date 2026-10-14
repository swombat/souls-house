"""PR350 review probes: fake Telegram only; no credentials or destinations."""

import asyncio
import unittest

from tests.helpers import Harness, fast_settings, wait_for
from connector.fake import World, PHONE, LOGIN_CODE


class PR350PhoneReviewRegressions(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.h = Harness(world=World(password="review-password", auto_scan=None),
                         settings=fast_settings(login_window=0.15))
        self.h.rails.connect("svc_1", "s" * 64)
        await self.command("start_login", generation=1, callback_secret="s" * 64,
                           callback_secret_version=1)
        await wait_for(lambda: self.h.world.qr_waiting.is_set())
        self.account = self.h.manager.account("svc_1")

    async def asyncTearDown(self):
        await self.h.close()

    async def command(self, op, **fields):
        return await self.h.manager.command("svc_1", op, fields)

    async def request(self):
        return await self.command("request_code", generation=1, phone="+" + PHONE)

    async def test_unsupported_phone_delivery_preserves_the_promised_qr_fallback(self):
        self.h.world.code_delivery = None
        self.assertEqual((200, {"outcome": "unsupported"}), await self.request())
        self.assertEqual("qr", self.account.login_phase,
                         "unsupported must not leave the fallback QR without a waiter")

    async def test_finish_failure_does_not_leave_pairing_without_a_deadline(self):
        self.h.world.password = None
        await self.request()
        self.h.world.fail["get_state"] = [RuntimeError("transient state failure")]
        try:
            await self.command("submit_code", generation=1, code=LOGIN_CODE)
        except RuntimeError:
            pass
        await asyncio.sleep(0.3)  # longer than the entire phone window
        self.assertNotEqual("logging_in", self.h.store.connection("svc_1")["status"],
                            "the code deadline must recover or fail the attempt")

    async def test_send_code_past_deadline_does_not_return_success_then_expire(self):
        send_entered, send_release = asyncio.Event(), asyncio.Event()
        original_send = self.account.client.send_code

        async def delayed_send(phone):
            send_entered.set()
            await send_release.wait()
            return await original_send(phone)

        self.account.client.send_code = delayed_send
        request = asyncio.create_task(self.request())
        await send_entered.wait()
        await asyncio.sleep(0.3)
        # Timeout has fired, but cannot acquire request_code's lock.
        self.assertEqual("logging_in", self.h.store.connection("svc_1")["status"])
        send_release.set()
        status, reply = await request
        await wait_for(lambda: self.h.store.connection("svc_1")["status"] == "failed")
        await wait_for(lambda: self.h.rails.connections["svc_1"]["login"].get("error") == "expired")
        self.assertNotEqual("code_sent", reply["outcome"],
                            f"late response {status, reply} races an expired callback")
