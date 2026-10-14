"""Signing in with the phone number and the code Telegram sends, instead of
the QR (Telegram refuses a login token opened on the phone it would
approve). Same attempt, same generation rules, same discipline as the
password: the number and the code are never stored, queued or logged."""

import asyncio
import logging
import os
import signal
import unittest

from telethon import errors

from connector.account import normalize_phone
from connector.fake import World
from tests import test_process
from tests.helpers import Harness, fast_settings, wait_for

# Long, distinctive canaries: short digit strings turn up by chance in a hex
# dump of the store.
PHONE = "+44 7700 900 123"
DIGITS = "447700900123"
CODE = "8642097531"


class Capture(logging.Handler):
    def __init__(self):
        super().__init__(logging.DEBUG)
        self.lines = []

    def emit(self, record):
        self.lines.append(f"{record.name} {record.getMessage()} {record.exc_text or ''}")


class PhoneLoginTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.capture = Capture()
        root = logging.getLogger()
        self.previous_level = root.level
        root.setLevel(logging.DEBUG)
        root.addHandler(self.capture)

    async def asyncTearDown(self):
        root = logging.getLogger()
        root.removeHandler(self.capture)
        root.setLevel(self.previous_level)
        await self.h.close()

    def harness(self, **world):
        world.setdefault("login_code", CODE)
        world.setdefault("phone", DIGITS)
        self.h = Harness(world=World(**world))
        return self.h

    async def start(self, h, generation=1):
        if "svc_1" not in h.rails.connections:
            h.rails.connect("svc_1", "s" * 64)
        status, reply = await h.manager.command("svc_1", "start_login", {
            "generation": generation, "callback_secret": "s" * 64, "callback_secret_version": 1})
        self.assertEqual(200, status, reply)
        await wait_for(lambda: h.world.qr_waiting.is_set())

    def rails(self, h):
        return h.rails.connections["svc_1"]

    def assert_never_kept(self, h, *secrets):
        dump = "\n".join(h.store.db.iterdump())
        with open(h.path, "rb") as handle:
            raw = handle.read()
        posted = repr(h.rails.posts)
        logs = "\n".join(self.capture.lines)
        for secret in secrets:
            self.assertNotIn(secret, dump, "in the store")
            self.assertNotIn(secret.encode(), raw, "in the store file")
            self.assertNotIn(secret, posted, "in an event to Rails")
            self.assertNotIn(secret, logs, "in the log")

    async def test_phone_then_code_signs_in_and_the_qr_loop_stops(self):
        h = self.harness()
        await self.start(h)
        await wait_for(lambda: self.rails(h)["qr"] is not None)
        account = h.manager.account("svc_1")
        fields = {"generation": 1, "phone": PHONE}
        status, reply = await h.manager.command("svc_1", "request_code", fields)
        self.assertEqual((200, {"outcome": "code_sent", "delivery": "app", "length": len(CODE),
                                "next_delivery": "sms", "timeout": 60}), (status, reply))
        self.assertNotIn("phone", fields, "the number is taken out of the command fields")
        self.assertEqual([DIGITS], h.world.phones_seen)
        await wait_for(lambda: self.rails(h)["login"].get("step") == "code")
        self.assertEqual("app", self.rails(h)["login"]["delivery"])
        self.assertIsNone(self.rails(h)["qr"])

        # No more QR codes for this attempt, and a scan now reaches nothing.
        self.assertFalse([name for name in account.tasks if name.startswith("qr-")])
        issued = h.world.qr_issued
        qr_posts = sum(1 for event in h.rails.posts if event["type"] == "login.qr")
        h.world.scanned.set()
        await asyncio.sleep(0.3)
        self.assertEqual(issued, h.world.qr_issued)
        self.assertEqual(qr_posts, sum(1 for event in h.rails.posts if event["type"] == "login.qr"))
        self.assertEqual(set(), h.world.sessions)

        status, reply = await h.manager.command("svc_1", "submit_code", {"generation": 1, "code": "1357924680"})
        self.assertEqual((200, {"outcome": "code_invalid"}), (status, reply))
        fields = {"generation": 1, "code": CODE}
        status, reply = await h.manager.command("svc_1", "submit_code", fields)
        self.assertEqual((200, {"outcome": "accepted"}), (status, reply))
        self.assertNotIn("code", fields, "the code is taken out of the command fields")
        await wait_for(lambda: self.rails(h)["status"] == "connected")
        self.assertEqual("1000", self.rails(h)["identity"]["user_id"])
        self.assertIsNone(account.phone_login)
        self.assert_never_kept(h, DIGITS, "7700 900 123", CODE)

    async def test_an_expired_code_asks_for_a_new_one(self):
        h = self.harness()
        await self.start(h)
        await h.manager.command("svc_1", "request_code", {"generation": 1, "phone": PHONE})
        h.world.code_expired = True
        status, reply = await h.manager.command("svc_1", "submit_code", {"generation": 1, "code": CODE})
        self.assertEqual((200, {"outcome": "code_expired"}), (status, reply))
        # Without a fresh code there is nothing to check against.
        status, reply = await h.manager.command("svc_1", "submit_code", {"generation": 1, "code": CODE})
        self.assertEqual((200, {"outcome": "code_expired"}), (status, reply))
        self.assertEqual(1, h.world.codes_sent)
        h.world.code_expired = False
        status, reply = await h.manager.command("svc_1", "request_code", {"generation": 1, "phone": PHONE})
        self.assertEqual("code_sent", reply["outcome"])
        status, reply = await h.manager.command("svc_1", "submit_code", {"generation": 1, "code": CODE})
        self.assertEqual((200, {"outcome": "accepted"}), (status, reply))
        await wait_for(lambda: self.rails(h)["status"] == "connected")

    async def test_two_step_password_after_the_code(self):
        password = "hunter2-PHONE-CANARY"
        h = self.harness(password=password)
        await self.start(h)
        await h.manager.command("svc_1", "request_code", {"generation": 1, "phone": PHONE})
        status, reply = await h.manager.command("svc_1", "submit_code", {"generation": 1, "code": CODE})
        self.assertEqual((200, {"outcome": "password_required"}), (status, reply))
        await wait_for(lambda: self.rails(h)["login"].get("step") == "password")
        self.assertEqual("the usual", self.rails(h)["login"]["hint"])
        # The code step is over: a code now is refused.
        status, reply = await h.manager.command("svc_1", "submit_code", {"generation": 1, "code": CODE})
        self.assertEqual((409, {"error": "not_waiting_for_code"}), (status, reply))
        status, reply = await h.manager.command("svc_1", "submit_password", {"generation": 1, "password": password})
        self.assertEqual((200, {"outcome": "accepted"}), (status, reply))
        await wait_for(lambda: self.rails(h)["status"] == "connected")
        self.assert_never_kept(h, DIGITS, CODE, password)

    async def test_stale_or_out_of_step_commands_are_refused(self):
        h = self.harness()
        # Before any attempt.
        h.rails.connect("svc_1", "s" * 64)
        status, reply = await h.manager.command("svc_1", "request_code", {"generation": 1, "phone": PHONE})
        self.assertEqual((409, {"error": "not_logging_in"}), (status, reply))
        await self.start(h)
        # A code before one was asked for.
        status, reply = await h.manager.command("svc_1", "submit_code", {"generation": 1, "code": CODE})
        self.assertEqual((409, {"error": "not_waiting_for_code"}), (status, reply))
        # Another generation's number and code.
        status, reply = await h.manager.command("svc_1", "request_code", {"generation": 2, "phone": PHONE})
        self.assertEqual((409, {"error": "not_logging_in"}), (status, reply))
        self.assertEqual(0, h.world.codes_sent)
        await h.manager.command("svc_1", "request_code", {"generation": 1, "phone": PHONE})
        status, reply = await h.manager.command("svc_1", "submit_code", {"generation": 2, "code": CODE})
        self.assertEqual((409, {"error": "not_waiting_for_code"}), (status, reply))
        status, reply = await h.manager.command("svc_1", "submit_code", {"generation": 1, "code": ""})
        self.assertEqual((422, {"error": "bad_code"}), (status, reply))
        status, reply = await h.manager.command("svc_1", "request_code", {"generation": 1, "phone": 447700900123})
        self.assertEqual((422, {"error": "bad_phone"}), (status, reply))
        # Cancelled: the attempt's code is gone with it.
        invalidated = h.rails.cancel_login("svc_1")
        await h.manager.command("svc_1", "cancel_login", {"generation": invalidated})
        status, reply = await h.manager.command("svc_1", "submit_code", {"generation": invalidated, "code": CODE})
        self.assertEqual((409, {"error": "not_waiting_for_code"}), (status, reply))
        status, reply = await h.manager.command("svc_1", "request_code", {"generation": invalidated, "phone": PHONE})
        self.assertEqual((409, {"error": "not_logging_in"}), (status, reply))
        self.assertEqual([], h.world.codes_seen)
        self.assertEqual(set(), h.world.sessions)

    async def test_a_number_without_a_country_code_is_refused_before_telegram_and_the_qr_stays(self):
        h = self.harness()
        await self.start(h)
        status, reply = await h.manager.command("svc_1", "request_code", {"generation": 1, "phone": "07700 900123"})
        self.assertEqual((200, {"outcome": "phone_invalid"}), (status, reply))
        self.assertEqual(0, h.world.codes_sent)
        account = h.manager.account("svc_1")
        self.assertEqual("qr", account.login_phase)
        self.assertIn("login", account.tasks)
        # The QR still signs in.
        h.world.scanned.set()
        await wait_for(lambda: self.rails(h)["status"] == "connected")

    async def test_telegram_refusals_at_request(self):
        h = self.harness()
        await self.start(h)
        h.world.fail["send_code"] = [errors.FloodWaitError(None, capture=42), errors.PhoneNumberInvalidError(None),
                                     errors.PhoneNumberBannedError(None), RuntimeError("boom")]
        replies = []
        for _ in range(4):
            _status, reply = await h.manager.command("svc_1", "request_code", {"generation": 1, "phone": PHONE})
            replies.append(reply)
        self.assertEqual([{"outcome": "flood_wait", "retry_after": 42}, {"outcome": "phone_invalid"},
                          {"outcome": "phone_banned"}, {"outcome": "failed"}], replies)
        h.world.fail["sign_in_code"] = [errors.FloodWaitError(None, capture=7)]
        await h.manager.command("svc_1", "request_code", {"generation": 1, "phone": PHONE})
        status, reply = await h.manager.command("svc_1", "submit_code", {"generation": 1, "code": CODE})
        self.assertEqual({"outcome": "flood_wait", "retry_after": 7}, reply)
        # A number with no Telegram account.
        h.world.phone = "15550001111"
        status, reply = await h.manager.command("svc_1", "submit_code", {"generation": 1, "code": CODE})
        self.assertEqual({"outcome": "phone_unregistered"}, reply)
        self.assert_never_kept(h, DIGITS, CODE)

    async def test_the_phone_path_has_its_own_window(self):
        self.h = h = Harness(world=World(login_code=CODE), settings=fast_settings(login_window=0.5))
        await self.start(h)
        await h.manager.command("svc_1", "request_code", {"generation": 1, "phone": PHONE})
        await wait_for(lambda: self.rails(h)["login"].get("error") == "expired", timeout=5)
        self.assertIsNone(h.store.connection("svc_1")["session"])
        status, reply = await h.manager.command("svc_1", "submit_code", {"generation": 1, "code": CODE})
        self.assertEqual((409, {"error": "not_waiting_for_code"}), (status, reply))


class NormalizePhoneTest(unittest.TestCase):
    def test_international_numbers_only(self):
        self.assertEqual(DIGITS, normalize_phone(PHONE))
        self.assertEqual(DIGITS, normalize_phone("0044 (7700) 900-123"))
        self.assertEqual("34612345678", normalize_phone("+34.612.345.678"))
        for bad in ("07700900123", "+0 7700900123", "+44 abc", "+123", "+1234567890123456", "", None, 44, "+" * 50):
            self.assertIsNone(normalize_phone(bad), bad)


class PhoneProcessTest(test_process.ProcessTest):
    """Through the real process: signed commands over mutual TLS, and the
    number, the code and the password nowhere in its log or on its volume."""

    async def test_phone_code_and_password_never_reach_the_log_or_the_volume(self):
        password = "PASSWORD-CANARY-" + os.urandom(4).hex()
        await self.spawn(TELEGRAM_FAKE_PASSWORD=password, TELEGRAM_FAKE_AUTO_SCAN="0",
                         TELEGRAM_FAKE_PHONE=DIGITS, TELEGRAM_FAKE_CODE=CODE)
        await self.listening()
        self.rails.connect("svc_1", "x" * 64)
        await self.command("svc_1", "start_login", {"generation": 1, "callback_secret": "x" * 64,
                                                    "callback_secret_version": 1})
        await wait_for(lambda: self.rails.connections["svc_1"]["qr"] is not None, timeout=10)
        status, reply = await self.command("svc_1", "request_code", {"generation": 1, "phone": PHONE})
        self.assertEqual((200, "code_sent"), (status, reply["outcome"]))
        status, reply = await self.command("svc_1", "submit_code", {"generation": 1, "code": CODE})
        self.assertEqual((200, {"outcome": "password_required"}), (status, reply))
        await wait_for(lambda: self.rails.connections["svc_1"]["login"].get("step") == "password", timeout=10)
        status, reply = await self.command("svc_1", "submit_password", {"generation": 1, "password": password})
        self.assertEqual((200, {"outcome": "accepted"}), (status, reply))
        await wait_for(lambda: self.rails.connections["svc_1"]["status"] == "connected", timeout=10)
        self.procs[-1].send_signal(signal.SIGTERM)
        self.assertEqual(0, await asyncio.wait_for(self.procs[-1].wait(), 15))
        log = self.read_log()
        self.assertIn("command done: op=submit_code", log)
        for secret in (DIGITS, "7700 900 123", CODE, password):
            self.assertNotIn(secret, log)
            self.assertNotIn(secret, repr(self.rails.posts))
        for name in os.listdir(self.data):
            with open(os.path.join(self.data, name), "rb") as handle:
                content = handle.read()
            for secret in (DIGITS, CODE, password):
                self.assertFalse(secret.encode() in content, f"a secret in {name}")


# Only the test above here: the inherited ones run in test_process.
for _name in dir(test_process.ProcessTest):
    if _name.startswith("test_"):
        setattr(PhoneProcessTest, _name, None)


if __name__ == "__main__":
    unittest.main()
