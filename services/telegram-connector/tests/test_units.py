import asyncio
import datetime
import hashlib
import json
import os
import tempfile
import unittest

from telethon.tl import types

from connector import commands, rails
from connector.store import NOOP_EVENT, Crypto, Store
from connector.sync import Ingest, chunks
from tests.helpers import FakeRails

UTC = datetime.timezone.utc


class SignatureVectorsTest(unittest.TestCase):
    """Computed by app/lib/comms_signature.rb and comms_command_signature.rb
    (bundle exec ruby, 2026-10-13), so both sides agree byte for byte."""

    def test_event_signature_matches_rails(self):
        body = '{"type":"message.upsert","messages":[{"body":"héllo 👋"}],"seq":3}'.encode()
        headers = rails.signed_headers("s3cret", "svc_7", "/internal/comms/connections/svc_7/events", body,
                                       now=1760000000, nonce="0123456789abcdef0123456789abcdef")
        self.assertEqual("ea60c5b79fff7d3b9157918bec50f42c5f1799da8365f47f8655cab77f649136", headers["X-Comms-Signature"])

    def test_command_signature_matches_rails(self):
        signature = commands.sign("command-key-0123456789abcdef0123456789", "k1", "svc_7", "start_login",
                                  "0123456789abcdef0123456789abcdef", 1760000000, b'{"generation":2}')
        self.assertEqual("f858712593e46c297370028c06184229b9d73bc0f740c55634323bbbfa5f5649", signature)


def signed_command(key, ref, operation, fields, now, command_id="a" * 32, key_id="k1"):
    body = json.dumps(dict(fields, connection=ref, operation=operation, command_id=command_id, issued_at=now)).encode()
    headers = {"X-Comms-Key-Id": key_id, "X-Comms-Command-Id": command_id, "X-Comms-Issued-At": str(now),
               "X-Comms-Command-Signature": commands.sign(key, key_id, ref, operation, command_id, now, body)}
    return headers, body


class CommandVerifyTest(unittest.TestCase):
    KEY = "c" * 40

    def verify(self, headers, body, ref="svc_1", operation="start_login", now=1000, seen=None):
        seen = set() if seen is None else seen
        def consume(command_id):
            if command_id in seen:
                return False
            seen.add(command_id)
            return True
        return commands.verify(keys={"k1": self.KEY}, headers=headers, connection=ref, operation=operation,
                               body=body, now=now, consume=consume)

    def test_accepts_a_good_command_once(self):
        headers, body = signed_command(self.KEY, "svc_1", "start_login", {"generation": 1}, 1000)
        seen = set()
        self.assertEqual(1, self.verify(headers, body, seen=seen)["generation"])
        with self.assertRaises(commands.Refused) as refused:
            self.verify(headers, body, seen=seen)
        self.assertEqual("replayed_command", refused.exception.code)

    def test_refusals(self):
        headers, body = signed_command(self.KEY, "svc_1", "start_login", {}, 1000)
        cases = {
            "stale_command": dict(now=1000 + 61),
            "bad_signature": dict(ref="svc_2"),
        }
        for code, overrides in cases.items():
            with self.assertRaises(commands.Refused) as refused:
                self.verify(headers, body, **overrides)
            self.assertEqual(code, refused.exception.code)
        with self.assertRaises(commands.Refused) as refused:
            self.verify(dict(headers, **{"X-Comms-Key-Id": "k9"}), body)
        self.assertEqual("unknown_key", refused.exception.code)
        other_headers, other_body = signed_command("d" * 40, "svc_1", "start_login", {}, 1000)
        with self.assertRaises(commands.Refused) as refused:
            self.verify(other_headers, other_body)
        self.assertEqual("bad_signature", refused.exception.code)


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.path = os.path.join(tempfile.mkdtemp(), "s.sqlite3")
        self.store = Store(self.path, Crypto("k" * 40))

    def test_secrets_are_sealed_per_connection(self):
        self.store.ensure_connection("svc_1")
        self.store.set_callback_secret("svc_1", "CANARY-secret", 1)
        self.store.set_session("svc_1", "CANARY-session")
        self.assertEqual("CANARY-secret", self.store.callback_secret("svc_1"))
        self.assertEqual("CANARY-session", self.store.session("svc_1"))
        self.store.db.execute("PRAGMA wal_checkpoint(FULL)")
        with open(self.path, "rb") as handle:
            self.assertNotIn(b"CANARY", handle.read())
        other = Store(self.path, Crypto("x" * 40))
        with self.assertRaises(Exception):
            other.session("svc_1")

    def test_set_aside_keeps_the_sequence_without_holes_and_carries_data_over(self):
        store = self.store
        store.ensure_connection("svc_1")
        with store.transaction():
            store.enqueue("svc_1", {"type": "message.upsert", "messages": [{"body": "keep"}]})
            store.enqueue("svc_1", {"type": "status.changed", "status": "logged_out", "generation": 1})
        store.set_aside_pending("svc_1", lambda event: event["type"] == "message.upsert")
        bodies = [json.loads(row["body"]) for row in store.pending("svc_1")]
        self.assertEqual([dict(NOOP_EVENT, seq=1), dict(NOOP_EVENT, seq=2)], bodies)
        with store.transaction():
            store.enqueue("svc_1", {"type": "status.changed", "status": "connected", "generation": 2})
            self.assertEqual(1, store.take_carryover("svc_1"))
        bodies = [json.loads(row["body"]) for row in store.pending("svc_1")]
        self.assertEqual([1, 2, 3, 4], [b["seq"] for b in bodies])
        self.assertEqual("keep", bodies[3]["messages"][0]["body"])

    def test_renumber_moves_every_row_past_what_rails_committed(self):
        store = self.store
        store.ensure_connection("svc_1")
        with store.transaction():
            for n in range(3):
                store.enqueue("svc_1", {"type": "message.upsert", "messages": [], "n": n})
        store.renumber("svc_1", 40)
        self.assertEqual([41, 42, 43], [json.loads(r["body"])["seq"] for r in store.pending("svc_1")])
        self.assertEqual(44, store.connection("svc_1")["next_seq"])


class DeliveryTest(unittest.IsolatedAsyncioTestCase):
    async def test_a_fresh_store_learns_rails_sequence_before_sending(self):
        store = Store(os.path.join(tempfile.mkdtemp(), "s.sqlite3"), Crypto("k" * 40))
        fake = FakeRails()
        connection = fake.connect("svc_1", "s" * 64, status="connected")
        connection["committed"] = 17  # Rails already committed 17 events from an earlier store
        store.ensure_connection("svc_1")
        store.set_callback_secret("svc_1", "s" * 64, 1)
        with store.transaction():
            store.enqueue("svc_1", {"type": "message.upsert", "messages": [
                {"provider_message_id": "1", "chat": "user:1", "sent_at": "2026-10-13T00:00:00Z", "body": "x"}]})
        outcome, count = await rails.Deliverer(store, "svc_1", fake.post).run_once()
        self.assertEqual((rails.Outcome.DONE, 1), (outcome, count))
        self.assertEqual(18, connection["committed"])
        self.assertEqual("x", connection["messages"][("user:1", "1")]["body"], "applied, not acknowledged unapplied")


class IngestTest(unittest.TestCase):
    def setUp(self):
        self.store = Store(os.path.join(tempfile.mkdtemp(), "s.sqlite3"), Crypto("k" * 40))
        self.store.ensure_connection("svc_1")

    def test_batches_are_bounded_in_items_and_bytes(self):
        items = [{"body": "é" * 4000} for _ in range(400)]
        batches = list(chunks(items))
        self.assertTrue(all(len(b) <= 200 for b in batches))
        self.assertTrue(all(len(json.dumps(b, ensure_ascii=False).encode()) <= 512 * 1024 + 1024 for b in batches))
        self.assertEqual(400, sum(len(b) for b in batches))

    def test_scope_from_a_difference(self):
        now = datetime.datetime.now(UTC)
        users = [types.User(id=1, is_self=True, first_name="Me"), types.User(id=2, first_name="Al"),
                 types.User(id=3, first_name="Bot", bot=True)]
        chats = [types.Channel(id=9, title="Big", photo=types.ChatPhotoEmpty(), date=now, megagroup=True,
                               participants_count=300)]
        diff = types.updates.Difference(
            new_messages=[types.Message(id=1, peer_id=types.PeerUser(2), date=now, message="hi"),
                          types.Message(id=2, peer_id=types.PeerUser(3), date=now, message="bot says")],
            new_encrypted_messages=[], users=users, chats=chats,
            other_updates=[types.UpdateNewChannelMessage(types.Message(id=5, peer_id=types.PeerChannel(9), date=now,
                                                                       message="big"), pts=2, pts_count=1)],
            state=types.updates.State(pts=3, qts=0, date=now, seq=0, unread_count=0))
        ingest = Ingest(self.store, "svc_1", 1)
        ingest.difference(diff)
        events = ingest.events()
        messages = [m for e in events if e["type"] == "message.upsert" for m in e["messages"]]
        self.assertEqual(["hi"], [m["body"] for m in messages])
        listed = {c["provider_chat_id"]: c["sync_state"] for e in events if e["type"] == "chat.upsert" for c in e["chats"]}
        self.assertEqual({"user:2": {"synced": True}, "user:3": {"synced": False, "reason": "bot"},
                          "channel:9": {"synced": False, "reason": "large_group"}}, listed)


if __name__ == "__main__":
    unittest.main()
