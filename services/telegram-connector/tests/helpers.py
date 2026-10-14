"""Test doubles: a fake Rails that applies events with the rules of
app/lib/comms_events.rb (sequence, generations, statuses, idempotent
messages, tombstones), and helpers to build a connector around the fake
Telegram world."""

import asyncio
import hashlib
import hmac
import json
import os
import tempfile

from connector.account import Account, Settings
from connector.fake import World
from connector.manager import Manager
from connector.store import Crypto, Store

LOGIN_EVENTS = {"pairing.qr", "login.qr", "login.code_sent", "login.password_required", "login.failed",
                "status.changed"}
STORE_KEY = "k" * 40


class Unreachable(Exception):
    pass


class FakeRails:
    def __init__(self):
        self.connections = {}
        self.down = False
        self.drop_ack = 0          # apply, then lose the reply (n times)
        self.refuse_types = {}     # event type -> status to answer, once per entry
        self.posts = []

    def connect(self, ref, secret, generation=1, status="pairing"):
        self.connections[ref] = {
            "secret": secret, "generation": generation, "status": status, "committed": 0, "chats": {},
            "messages": {}, "login": {}, "qr": None, "availability": None, "revoked": False,
            "identity": None, "nonces": set(), "applied": [], "checkpoints": {}, "unresolved": 0,
        }
        return self.connections[ref]

    async def post(self, path, body, headers):
        if self.down:
            raise Unreachable()
        ref = path.split("/")[4]
        connection = self.connections[ref]
        if connection["revoked"]:
            return 410, {"error": "connection_revoked"}
        signed = "\n".join([ref, "POST", path, headers["X-Comms-Timestamp"], headers["X-Comms-Nonce"], body.decode()])
        expected = hmac.new(connection["secret"].encode(), signed.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, headers["X-Comms-Signature"]) or headers["X-Comms-Connection"] != ref:
            return 401, {"error": "bad_signature"}
        if headers["X-Comms-Nonce"] in connection["nonces"]:
            return 401, {"error": "replayed_nonce"}
        event = json.loads(body)
        self.posts.append(event)
        status = self.refuse_types.get(event.get("type"))
        if status:
            return status, {"error": "refused_for_test"}
        seq = event.get("seq")
        if seq is not None:
            if seq <= connection["committed"]:
                return 200, {"committed_seq": connection["committed"]}
            if seq > connection["committed"] + 1:
                return 409, {"error": "sequence_gap", "committed_seq": connection["committed"]}
        try:
            self.apply(connection, event)
        except Refused as refused:
            if seq is not None and event["type"] in LOGIN_EVENTS and refused.code in (
                    "stale_generation", "stale_qr", "expired_qr", "connection_not_accepting"):
                connection["nonces"].add(headers["X-Comms-Nonce"])
                connection["committed"] = seq
                return 200, {"committed_seq": seq, "skipped": refused.code}
            return refused.status, {"error": refused.code}
        connection["nonces"].add(headers["X-Comms-Nonce"])
        if seq is not None:
            connection["committed"] = seq
        if self.drop_ack:
            self.drop_ack -= 1
            raise Unreachable()
        return (200, {"committed_seq": connection["committed"]}) if seq is not None else (204, {})

    def apply(self, c, event):
        kind = event["type"]
        def need(*statuses):
            if c["status"] not in statuses:
                raise Refused("connection_not_accepting", 409)
        def generation():
            if event.get("generation") != c["generation"]:
                raise Refused("stale_generation", 409)
        if kind == "chat.upsert":
            need("connected")
            for chat in event["chats"]:
                current = c["chats"].setdefault(chat["provider_chat_id"], {})
                state = dict(current.get("sync_state", {}))
                state.update(chat.get("sync_state", {}))
                current.update({k: v for k, v in chat.items() if k != "sync_state"})
                current["sync_state"] = state
        elif kind == "message.upsert":
            need("connected")
            assert len(event["messages"]) <= 200
            for message in event["messages"]:
                key = (message["chat"], message["provider_message_id"])
                existing = c["messages"].get(key)
                if existing is None:
                    c["messages"][key] = dict(message)
                elif not existing.get("deleted") and message.get("edited_at") and \
                        (existing.get("edited_at") or "") < message["edited_at"]:
                    existing.update(message)
        elif kind == "message.edit":
            need("connected")
            for edit in event["messages"]:
                key = (edit["chat"], edit["provider_message_id"])
                existing = c["messages"].setdefault(key, {"placeholder": True})
                if not existing.get("deleted") and (existing.get("edited_at") or "") < edit["edited_at"]:
                    existing.update(edit)
        elif kind == "message.delete":
            need("connected")
            for deletion in event["deletions"]:
                for mid in deletion["provider_message_ids"]:
                    existing = c["messages"].setdefault((deletion["chat"], mid), {})
                    existing.update({"deleted": True, "body": None, "caption": None})
            c["unresolved"] += event.get("unresolved", 0)
        elif kind == "sync.checkpoint":
            need("connected")
            for chat in event["chats"]:
                c["checkpoints"][chat["provider_chat_id"]] = chat["synced_through"]
        elif kind == "status.changed":
            if event["status"] == "connected":
                need("pairing", "connected")
                generation()
                c["status"] = "connected"
                c["identity"] = event.get("identity")
            elif event["status"] == "logged_out":
                need("pairing", "connected")
                generation()
                c["status"] = "reauthorizing"
            c["login"] = {}
            c["qr"] = None
        elif kind == "login.qr":
            need("pairing")
            generation()
            if c["login"].get("step") == "code":
                raise Refused("stale_qr", 409)
            c["qr"] = event["code"]
        elif kind == "login.code_sent":
            need("pairing")
            generation()
            c["login"] = {"step": "code", "delivery": event["delivery"]}
            c["qr"] = None
        elif kind == "login.password_required":
            need("pairing")
            generation()
            c["login"] = {"step": "password", "hint": event.get("hint")}
            c["qr"] = None
        elif kind == "login.failed":
            need("pairing")
            generation()
            c["login"] = {"error": event["code"], "retry_after": event.get("retry_after")}
        elif kind == "connector.availability":
            c["availability"] = event["state"]
        else:
            raise Refused("unknown_event", 422)
        c["applied"].append(kind)

    # Rails-side transitions (what the owner's clicks do)
    def begin_login(self, ref):
        c = self.connections[ref]
        c["generation"] += 1
        c["status"] = "pairing"
        c["login"] = {}
        return c["generation"]

    def cancel_login(self, ref):
        c = self.connections[ref]
        invalidated = c["generation"]
        c["generation"] += 1
        return invalidated

    def bodies(self, ref, chat):
        c = self.connections[ref]
        return {mid: m.get("body") for (ch, mid), m in c["messages"].items() if ch == chat}


class Refused(Exception):
    def __init__(self, code, status):
        super().__init__(code)
        self.code = code
        self.status = status


def fast_settings(**overrides):
    values = dict(poll_interval=0.05, backfill_pause=0.0, checkpoint_interval=0.2, channel_poll_interval=0.2,
                  dialog_refresh=3600.0, retry_max=0.05, delivery_idle=0.05, login_window=5.0,
                  password_window=5.0, qr_max_lifetime=30.0)
    values.update(overrides)
    return Settings(**values)


class Harness:
    """A connector (store + manager) around a fake Telegram and a fake Rails."""

    def __init__(self, world=None, settings=None, path=None):
        self.dir = tempfile.mkdtemp(prefix="tg-test-")
        self.path = path or os.path.join(self.dir, "store.sqlite3")
        self.world = world or World(auto_scan=None, qr_ttl=30)
        self.rails = FakeRails()
        self.settings = settings or fast_settings()
        self.open()

    def open(self):
        self.store = Store(self.path, Crypto(STORE_KEY))
        self.manager = Manager(self.store, self.world.factory, self.rails.post, self.settings, b"log")

    async def restart(self):
        """A new process on the same store and the same Telegram."""
        await self.manager.close()
        self.store.db.close()
        for client in list(self.world.clients):
            await client.disconnect()
        self.open()
        await self.manager.boot()

    async def connect(self, ref="svc_1", secret="s" * 64):
        """Owner presses Connect; the QR is scanned; the account syncs."""
        self.rails.connect(ref, secret)
        status, reply = await self.manager.command(ref, "start_login", {
            "generation": 1, "callback_secret": secret, "callback_secret_version": 1})
        assert status == 200, reply
        await wait_for(lambda: self.world.qr_waiting.is_set())
        self.world.scanned.set()
        await wait_for(lambda: self.rails.connections[ref]["status"] == "connected")
        return self.manager.account(ref)

    async def close(self):
        await self.manager.close()
        self.store.db.close()


async def wait_for(predicate, timeout=5.0, interval=0.01):
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while not predicate():
        if loop.time() > deadline:
            raise AssertionError("timed out waiting")
        await asyncio.sleep(interval)


async def settle(account, rails_connection=None, timeout=5.0):
    """Waits until backfill is done and the outbox is empty."""
    store, ref = account.store, account.ref
    await wait_for(lambda: not store.pending_backfill(ref) and store.pending_count(ref) == 0, timeout)
