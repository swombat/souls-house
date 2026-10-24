"""The real connector process (python -m connector) with the fake Telegram,
real mutual TLS, real signatures, a fake Rails over HTTP, real SIGKILLs."""

import asyncio
import json
import os
import signal
import socket
import ssl
import sys
import tempfile
import time
import unittest

import aiohttp
from aiohttp import web

from connector import commands
from connector.fake import ALICE
from tests import tls
from tests.helpers import FakeRails, wait_for

SERVICE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMMAND_KEY = "c" * 48
CANARY = "CANARY-tg-" + os.urandom(4).hex()


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class ProcessTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.dir = tempfile.mkdtemp(prefix="tg-proc-")
        self.data = os.path.join(self.dir, "data")
        os.mkdir(self.data)
        self.tls = tls.write(os.path.join(self.dir, "tls"))
        self.rails = FakeRails()
        app = web.Application()

        async def events(request):
            body = await request.read()
            try:
                status, reply = await self.rails.post(request.path, body, request.headers)
            except Exception:
                raise web.HTTPServiceUnavailable()
            return web.json_response(reply, status=status) if status != 204 else web.Response(status=204)
        app.router.add_post("/internal/comms/connections/{ref}/events", events)
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        self.rails_port = free_port()
        await web.TCPSite(self.runner, "127.0.0.1", self.rails_port).start()
        self.procs = []

    async def asyncTearDown(self):
        for proc in self.procs:
            if proc.returncode is None:
                proc.kill()
                await proc.wait()
        await self.runner.cleanup()

    def env(self, **overrides):
        env = {
            "PATH": os.environ.get("PATH", ""), "PYTHONPATH": SERVICE_DIR,
            "COMMS_STORE_KEY": "s" * 44, "COMMS_COMMAND_KEY": COMMAND_KEY,
            "COMMS_RAILS_URL": f"http://127.0.0.1:{self.rails_port}",
            "COMMS_TLS_CERT": self.tls["server_cert"], "COMMS_TLS_KEY": self.tls["server_key"],
            "COMMS_TLS_CLIENT_CA": self.tls["ca"], "COMMS_TLS_CLIENT_NAME": "rails",
            "COMMS_DATA_DIR": self.data, "TELEGRAM_PROVIDER": "fake", "COMMS_ALLOW_FAKE": "1",
            "TELEGRAM_FAKE_DIR": os.path.join(self.dir, "telegram"), "TELEGRAM_FAKE_MARKER": CANARY,
        }
        env.update({k: v for k, v in overrides.items() if v is not None})
        for k, v in overrides.items():
            if v is None:
                env.pop(k, None)
        return env

    async def spawn(self, port=None, **overrides):
        self.port = port or getattr(self, "port", None) or free_port()
        self.log = open(os.path.join(self.dir, "connector.log"), "ab")
        proc = await asyncio.create_subprocess_exec(
            sys.executable, "-m", "connector", cwd=SERVICE_DIR, stdout=self.log, stderr=self.log,
            env=self.env(COMMS_LISTEN=f"127.0.0.1:{self.port}", **overrides))
        self.procs.append(proc)
        return proc

    def read_log(self):
        with open(os.path.join(self.dir, "connector.log"), "rb") as handle:
            return handle.read().decode(errors="replace")

    async def listening(self, timeout=10):
        def up():
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                    return True
            except OSError:
                return False
        await wait_for(up, timeout=timeout, interval=0.05)

    def client_context(self, cert=None, key=None):
        context = ssl.create_default_context(cafile=self.tls["ca"])
        if cert:
            context.load_cert_chain(cert, key)
        return context

    async def command(self, ref, operation, fields, context=None, key=COMMAND_KEY):
        now = int(time.time())
        command_id = os.urandom(16).hex()
        body = json.dumps(dict(fields, connection=ref, operation=operation, command_id=command_id,
                               issued_at=now)).encode()
        headers = {"Content-Type": "application/json", "X-Comms-Key-Id": "k1", "X-Comms-Command-Id": command_id,
                   "X-Comms-Issued-At": str(now),
                   "X-Comms-Command-Signature": commands.sign(key, "k1", ref, operation, command_id, now, body)}
        context = context or self.client_context(self.tls["client_cert"], self.tls["client_key"])
        async with aiohttp.ClientSession() as session:
            async with session.post(f"https://127.0.0.1:{self.port}/connections/{ref}/{operation}",
                                    data=body, headers=headers, ssl=context) as response:
                return response.status, await response.json()

    async def connect_account(self, ref="svc_1"):
        self.rails.connect(ref, "x" * 64)
        status, reply = await self.command(ref, "start_login", {
            "generation": 1, "callback_secret": "x" * 64, "callback_secret_version": 1})
        self.assertEqual(200, status, reply)
        await wait_for(lambda: self.rails.connections[ref]["status"] == "connected", timeout=10)

    def live(self, ref="svc_1"):
        return {b for b in self.rails.bodies(ref, f"user:{ALICE}").values() if b and b.startswith("live")}

    # -- the tests -----------------------------------------------------------------

    async def test_refuses_to_start_without_mutual_tls_material(self):
        for missing in ("COMMS_TLS_CERT", "COMMS_TLS_KEY", "COMMS_TLS_CLIENT_CA"):
            proc = await self.spawn(**{missing: None})
            self.assertEqual(2, await asyncio.wait_for(proc.wait(), 10))
        self.assertEqual(3, self.read_log().count("startup refused: reason=tls"))
        proc = await self.spawn(COMMS_COMMAND_KEY="short")
        self.assertEqual(2, await asyncio.wait_for(proc.wait(), 10))
        proc = await self.spawn(TELEGRAM_PROVIDER="telethon", TELEGRAM_API_ID=None)
        self.assertEqual(2, await asyncio.wait_for(proc.wait(), 10))
        self.assertIn("reason=telegram_app", self.read_log())

    async def test_mutual_tls_and_signed_commands_only(self):
        await self.spawn()
        await self.listening()
        # No client certificate: the handshake fails.
        with self.assertRaises((aiohttp.ClientError, ssl.SSLError, ConnectionError)):
            await self.command("svc_1", "logout", {}, context=self.client_context())
        # A certificate from another CA: refused.
        other = tls.write(os.path.join(self.dir, "other"))
        with self.assertRaises((aiohttp.ClientError, ssl.SSLError, ConnectionError)):
            await self.command("svc_1", "logout", {}, context=self.client_context(other["client_cert"], other["client_key"]))
        # The house CA, but not Rails's name.
        cert, key = self.tls["issue"]("not-rails")
        status, reply = await self.command("svc_1", "logout", {}, context=self.client_context(cert, key))
        self.assertEqual((403, {"error": "client_not_allowed"}), (status, reply))
        # Rails's certificate and a good signature.
        status, _ = await self.command("svc_1", "logout", {})
        self.assertEqual(200, status)
        # The right certificate but the wrong command key.
        status, reply = await self.command("svc_1", "logout", {}, key="d" * 48)
        self.assertEqual((401, {"error": "bad_signature"}), (status, reply))

    async def test_connect_live_messages_and_a_sigkill_between_outbox_and_state(self):
        # The process dies (os._exit) in the middle of the second live ingest
        # transaction: outbox rows written, state not, nothing committed.
        await self.spawn(TELEGRAM_FAKE_LIVE="6", TELEGRAM_FAKE_LIVE_INTERVAL="1.0",
                         COMMS_FAULT="live:after_outbox", COMMS_FAULT_AT="2")
        await self.listening()
        await self.connect_account()
        proc = self.procs[-1]
        self.assertEqual(-signal.SIGKILL if False else 137, await asyncio.wait_for(proc.wait(), 20))
        self.assertTrue(os.path.exists(os.path.join(self.dir, "telegram", "crashed-live-after_outbox")))
        delivered_before = self.live()
        await self.spawn(TELEGRAM_FAKE_LIVE="6", TELEGRAM_FAKE_LIVE_INTERVAL="1.0")
        await wait_for(lambda: self.live() == {f"live {n}{CANARY}" for n in range(6)}, timeout=20)
        self.assertLess(len(delivered_before), 6)
        # Search through the process, then logout.
        status, reply = await self.command("svc_1", "search", {"query": "live 3", "scope": "synced", "limit": 5})
        self.assertEqual(200, status)
        self.assertEqual([f"live 3{CANARY}"], [r["body"] for r in reply["results"]])
        status, reply = await self.command("svc_1", "logout", {})
        self.assertEqual((200, {"status": "logged_out"}), (status, reply))
        log = self.read_log()
        self.assertIn("command done: op=start_login", log)
        self.assertNotIn(CANARY, log)
        self.assertNotIn("svc_1", log)
        self.assertNotIn("x" * 64, log)

    async def test_two_step_password_never_reaches_the_log_or_the_store(self):
        password = "PASSWORD-CANARY-" + os.urandom(4).hex()
        await self.spawn(TELEGRAM_FAKE_PASSWORD=password)
        await self.listening()
        self.rails.connect("svc_1", "x" * 64)
        await self.command("svc_1", "start_login", {"generation": 1, "callback_secret": "x" * 64,
                                                    "callback_secret_version": 1})
        await wait_for(lambda: self.rails.connections["svc_1"]["login"].get("step") == "password", timeout=10)
        status, reply = await self.command("svc_1", "submit_password", {"generation": 1, "password": "wrong-" + password})
        self.assertEqual((200, {"outcome": "password_invalid"}), (status, reply))
        status, reply = await self.command("svc_1", "submit_password", {"generation": 1, "password": password})
        self.assertEqual((200, {"outcome": "accepted"}), (status, reply))
        await wait_for(lambda: self.rails.connections["svc_1"]["status"] == "connected", timeout=10)
        self.procs[-1].send_signal(signal.SIGTERM)
        self.assertEqual(0, await asyncio.wait_for(self.procs[-1].wait(), 15))
        log = self.read_log()
        self.assertNotIn(password, log)
        self.assertNotIn(CANARY, log)
        # Neither the password nor any message content is on the volume in
        # clear (the outbox is sealed like the session).
        for name in os.listdir(self.data):
            with open(os.path.join(self.data, name), "rb") as handle:
                content = handle.read()
            self.assertFalse(password.encode() in content, f"password in {name}")
            self.assertFalse(CANARY.encode() in content, f"message content in {name}")

    async def test_single_owner_a_second_process_waits_until_the_first_is_gone(self):
        first = await self.spawn(TELEGRAM_FAKE_LIVE="30", TELEGRAM_FAKE_LIVE_INTERVAL="0.5")
        await self.listening()
        await self.connect_account()
        second_port = free_port()
        second = await self.spawn(port=second_port, TELEGRAM_FAKE_LIVE="30", TELEGRAM_FAKE_LIVE_INTERVAL="0.5")
        await wait_for(lambda: "waiting for the data lease" in self.read_log(), timeout=10)
        await asyncio.sleep(1.0)
        # The second process opened nothing: no server, no Telegram client.
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", second_port), timeout=0.2).close()
        self.assertEqual(1, self.read_log().count('"msg": "started"'))
        first.kill()
        await first.wait()
        await self.listening(timeout=10)  # self.port is now the second's
        await wait_for(lambda: self.read_log().count('"msg": "started"') == 2, timeout=10)
        count = len(self.live())
        await wait_for(lambda: len(self.live()) > count + 2, timeout=15)
        self.assertIsNone(second.returncode)


if __name__ == "__main__":
    unittest.main()
