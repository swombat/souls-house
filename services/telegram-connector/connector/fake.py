"""A fake Telegram for tests and the Rails end-to-end test.

Not a mock of Telethon's client: a small model of the parts of Telegram the
connector uses (QR login, or a phone number and the code Telegram sends to
the account's app, with an optional two-step password; the common
update box with pts, per-channel pts, getDifference / getChannelDifference
slices, dialogs, history, search, logout), answering with real Telethon TL
objects so the connector's conversion runs on the real types.

The process only loads it with TELEGRAM_PROVIDER=fake and COMMS_ALLOW_FAKE=1.
With TELEGRAM_FAKE_DIR set, sessions and the world's start time persist
there, so a restarted connector process finds the same Telegram (the live
messages are scheduled from that start time, so they keep arriving across
restarts, and a replay after a crash finds the same pts).
"""

import asyncio
import datetime
import json
import os
import secrets

from telethon import errors
from telethon.tl import types

from .telegram import Dialog

UTC = datetime.timezone.utc
SELF_ID = 1000
ALICE, BOT, BOB = 2001, 2002, 2003
FAMILY = 3001                     # basic group
TEAM, NEWS, BIG = 4001, 4002, 4003  # small megagroup, broadcast, large megagroup
PHONE = "447700900123"            # the account's number, as Telegram's digits
LOGIN_CODE = "24680"


def now():
    return datetime.datetime.now(UTC).replace(microsecond=0)


class Entry:
    """One change in a pts box."""

    def __init__(self, pts, kind, message=None, ids=None, visible_at=None, channel=None):
        self.pts = pts
        self.kind = kind          # new | edit | delete
        self.message = message
        self.ids = ids or []
        self.visible_at = visible_at
        self.channel = channel


class FakeQR:
    def __init__(self, world, client):
        self.world = world
        self.client = client
        self.recreate_sync()

    def recreate_sync(self):
        self.token = secrets.token_urlsafe(16)
        self.expires = now() + datetime.timedelta(seconds=self.world.qr_ttl)
        self.world.qr_issued += 1

    @property
    def url(self):
        return f"tg://login?token={self.token}"

    async def recreate(self):
        self.world.check("recreate")
        self.recreate_sync()

    async def wait(self, timeout=None):
        world = self.world
        world.qr_waiting.set()
        try:
            await asyncio.wait_for(world.scanned.wait(), timeout)
        except asyncio.TimeoutError:
            raise
        world.scanned.clear()
        world.check("qr_wait")
        if world.password is not None:
            raise errors.SessionPasswordNeededError(None)
        world.add_session(self.client.session)
        return world.users[SELF_ID]


class FakeTelegram:
    """One client (one session) in the world."""

    def __init__(self, world, session):
        self.world = world
        self.session = session or f"fake-{secrets.token_hex(8)}"
        self.connected = False
        self.push = None
        self.signed_in_pending = False
        world.clients.append(self)

    def on_push(self, callback):
        self.push = callback

    async def connect(self):
        self.world.check("connect")
        self.connected = True

    async def disconnect(self):
        self.connected = False
        if self in self.world.clients:
            self.world.clients.remove(self)

    def is_connected(self):
        return self.connected

    def _authorized(self):
        if self.world.revoked:
            raise errors.AuthKeyUnregisteredError(None)

    async def is_authorized(self):
        return self.session in self.world.sessions and not self.world.revoked

    def session_string(self):
        return self.session

    async def begin_qr(self):
        self.world.check("begin_qr")
        if self.world.auto_scan:
            asyncio.get_running_loop().call_later(self.world.auto_scan, self.world.scanned.set)
        return FakeQR(self.world, self)

    async def send_code(self, phone):
        """auth.sendCode: any well-formed number gets a code (Telegram only
        says there is no account at signIn). The code goes to the app."""
        world = self.world
        world.check("send_code")
        world.phones_seen.append(phone)
        world.codes_sent += 1
        code_hash = secrets.token_hex(8)
        world.code_hashes[code_hash] = phone
        return {"hash": code_hash, "delivery": world.code_delivery, "length": len(world.login_code),
                "next_delivery": "sms", "timeout": 60}

    async def sign_in_code(self, phone, code, phone_code_hash):
        world = self.world
        world.check("sign_in_code")
        world.codes_seen.append(code)
        if world.code_hashes.get(phone_code_hash) != phone or world.code_expired:
            world.code_hashes.pop(phone_code_hash, None)
            raise errors.PhoneCodeExpiredError(None)
        if code != world.login_code:
            raise errors.PhoneCodeInvalidError(None)
        if phone != world.phone:
            raise errors.PhoneNumberUnoccupiedError(None)
        world.code_hashes.pop(phone_code_hash, None)
        if world.password is not None:
            raise errors.SessionPasswordNeededError(None)
        world.add_session(self.session)
        return world.users[SELF_ID]

    async def password_hint(self):
        return self.world.password_hint

    async def sign_in_password(self, password):
        self.world.check("sign_in_password")
        self.world.passwords_seen += 1
        if password != self.world.password:
            raise errors.PasswordHashInvalidError(None)
        self.world.add_session(self.session)
        return self.world.users[SELF_ID]

    async def me(self):
        self._authorized()
        return self.world.users[SELF_ID]

    async def log_out(self):
        self.world.check("log_out")
        self.world.logouts += 1
        self.world.remove_session(self.session)
        self.connected = False
        return True

    async def get_state(self):
        self._authorized()
        self.world.check("get_state")
        return types.updates.State(pts=self.world.visible_pts(), qts=0, date=now(), seq=0, unread_count=0)

    async def get_difference(self, pts, date, qts):
        self._authorized()
        self.world.check("get_difference")
        self.world.requests.append(("get_difference", pts))
        return self.world.difference(pts)

    async def get_channel_difference(self, channel_id, pts, limit=100):
        self._authorized()
        self.world.check("get_channel_difference")
        self.world.requests.append(("get_channel_difference", channel_id, pts))
        return self.world.channel_difference(channel_id, pts, limit)

    async def dialogs(self):
        self._authorized()
        self.world.check("dialogs")
        return self.world.dialogs()

    async def participants(self, channel_id):
        self._authorized()
        self.world.check("participants")
        return self.world.participant_counts[channel_id]

    async def history(self, chat_key, offset_id, limit):
        self._authorized()
        self.world.check("history")
        self.world.requests.append(("history", chat_key, offset_id))
        return self.world.history(chat_key, offset_id, limit), list(self.world.users.values()), list(self.world.chats.values())

    async def search(self, query, chat_key, limit):
        self._authorized()
        self.world.check("search")
        return self.world.search(query, chat_key, limit), list(self.world.users.values()), list(self.world.chats.values())


class World:
    def __init__(self, directory="", marker=None, history_days=40, history_per_day=1, live=0, live_interval=1.0,
                 password=None, auto_scan=None, qr_ttl=30, slice_size=50, phone=PHONE, login_code=LOGIN_CODE):
        env = os.environ
        if directory:
            os.makedirs(directory, exist_ok=True)
            marker = env.get("TELEGRAM_FAKE_MARKER", marker)
            live = int(env.get("TELEGRAM_FAKE_LIVE", live))
            live_interval = float(env.get("TELEGRAM_FAKE_LIVE_INTERVAL", live_interval))
            password = env.get("TELEGRAM_FAKE_PASSWORD", password)
            # 0 turns the automatic QR scan off (the phone-code path's e2e).
            auto_scan = float(env.get("TELEGRAM_FAKE_AUTO_SCAN", 0.5))
            phone = env.get("TELEGRAM_FAKE_PHONE", phone)
            login_code = env.get("TELEGRAM_FAKE_CODE", login_code)
        self.directory = directory
        self.marker = marker or ""
        self.password = password
        self.password_hint = "the usual" if password else None
        self.auto_scan = auto_scan
        self.qr_ttl = qr_ttl
        self.phone = phone
        self.login_code = login_code
        self.code_delivery = "app"
        self.code_expired = False
        self.code_hashes = {}
        self.codes_sent = 0
        self.phones_seen = []
        self.codes_seen = []
        self.slice_size = slice_size
        self.scanned = asyncio.Event() if _loop_ok() else None
        self.qr_waiting = asyncio.Event() if _loop_ok() else None
        self.qr_issued = 0
        self.passwords_seen = 0
        self.logouts = 0
        self.revoked = False
        self.fail = {}
        self.requests = []
        self.clients = []
        self.crash_counts = {}
        self.too_long_below = 0
        state = self._load()
        self.t0 = datetime.datetime.fromtimestamp(state["t0"], UTC)
        self.sessions = set(state["sessions"])
        self._build(history_days, history_per_day, live, live_interval)

    # -- persistence (e2e) ----------------------------------------------------

    def _path(self):
        return os.path.join(self.directory, "world.json") if self.directory else None

    def _load(self):
        path = self._path()
        if path and os.path.exists(path):
            with open(path) as handle:
                return json.load(handle)
        state = {"t0": now().timestamp(), "sessions": []}
        self._save(state)
        return state

    def _save(self, state=None):
        path = self._path()
        if not path:
            return
        state = state or {"t0": self.t0.timestamp(), "sessions": sorted(self.sessions)}
        with open(path + ".tmp", "w") as handle:
            json.dump(state, handle)
        os.replace(path + ".tmp", path)

    def add_session(self, session):
        self.sessions.add(session)
        self._save()

    def remove_session(self, session):
        self.sessions.discard(session)
        self._save()

    def factory(self, session):
        return FakeTelegram(self, session)

    def settings(self):
        from .account import Settings
        return Settings(poll_interval=0.3, backfill_pause=0.02, checkpoint_interval=1.0, channel_poll_interval=1.0,
                        dialog_refresh=60.0, retry_max=1.0, delivery_idle=0.5, qr_max_lifetime=60.0)

    def should_crash(self, name):
        """For COMMS_FAULT: crash once, at the COMMS_FAULT_AT'th time the point
        is reached (a marker file stops the restarted process crashing again)."""
        marker = os.path.join(self.directory, f"crashed-{name.replace(':', '-')}")
        if not self.directory or os.path.exists(marker):
            return False
        self.crash_counts[name] = self.crash_counts.get(name, 0) + 1
        if self.crash_counts[name] < int(os.environ.get("COMMS_FAULT_AT", "1")):
            return False
        with open(marker, "w") as handle:
            handle.write("1")
        return True

    # -- failure injection (unit tests) --------------------------------------------

    def check(self, method):
        queue = self.fail.get(method)
        if queue:
            error = queue.pop(0)
            if error is not None:
                raise error

    # -- the model ------------------------------------------------------------------

    def _user(self, uid, first, last=None, username=None, bot=False):
        return types.User(id=uid, is_self=uid == SELF_ID, first_name=first, last_name=last, username=username,
                          bot=bot, access_hash=uid * 7)

    def _build(self, history_days, per_day, live, live_interval):
        m = self.marker
        self.users = {
            SELF_ID: self._user(SELF_ID, "Daniel", username="daniel"),
            ALICE: self._user(ALICE, f"Alice{m}"),
            BOT: self._user(BOT, "Helper", username="helper_bot", bot=True),
            BOB: self._user(BOB, "Bob"),
        }
        self.chats = {
            FAMILY: types.Chat(id=FAMILY, title=f"Family{m}", photo=types.ChatPhotoEmpty(), participants_count=4,
                               date=self.t0, version=1),
            TEAM: types.Channel(id=TEAM, title="Small team", photo=types.ChatPhotoEmpty(), date=self.t0,
                                megagroup=True, access_hash=TEAM * 7),
            NEWS: types.Channel(id=NEWS, title="News", photo=types.ChatPhotoEmpty(), date=self.t0,
                                broadcast=True, access_hash=NEWS * 7),
            BIG: types.Channel(id=BIG, title="Big group", photo=types.ChatPhotoEmpty(), date=self.t0,
                               megagroup=True, access_hash=BIG * 7),
        }
        self.participant_counts = {TEAM: 5, BIG: 900, NEWS: 10_000}
        self.next_id = 1                 # the account-wide id sequence (DMs, basic groups)
        self.channel_next_id = {TEAM: 1, NEWS: 1, BIG: 1}
        self.log = []                    # common box
        self.channel_logs = {TEAM: [], NEWS: [], BIG: []}   # a channel's pts starts at 1
        self.history_seed = []           # messages that predate the session
        start = self.t0 - datetime.timedelta(days=history_days)
        for day in range(history_days):
            for n in range(per_day):
                at = start + datetime.timedelta(days=day, minutes=n)
                self.history_seed.append(self._message(f"user:{ALICE}", f"old {day}.{n}{m}", at, sender=ALICE))
                self.history_seed.append(self._message(f"chat:{FAMILY}", f"family {day}.{n}", at, sender=BOB))
                self.history_seed.append(self._message(f"channel:{TEAM}", f"team {day}.{n}", at, sender=BOB))
        self.history_seed.append(self._message(f"user:{SELF_ID}", f"note to self{m}", self.t0 - datetime.timedelta(hours=1),
                                               sender=SELF_ID, out=True))
        photo = self._message(f"user:{ALICE}", f"a photo caption{m}", self.t0 - datetime.timedelta(minutes=30), sender=ALICE)
        photo.media = types.MessageMediaPhoto(photo=types.PhotoEmpty(id=1))
        self.history_seed.append(photo)
        for i in range(live):
            at = self.t0 + datetime.timedelta(seconds=live_interval * (i + 1))
            self.add_message(f"user:{ALICE}", f"live {i}{m}", at=at, sender=ALICE)

    def _message(self, chat_key, text, at, sender=None, out=False):
        kind, _, value = chat_key.partition(":")
        number = int(value)
        if kind == "channel":
            mid = self.channel_next_id[number]
            self.channel_next_id[number] += 1
            peer = types.PeerChannel(number)
        else:
            mid = self.next_id
            self.next_id += 1
            peer = types.PeerUser(number) if kind == "user" else types.PeerChat(number)
        from_id = types.PeerUser(sender) if sender and (kind != "user" or out) else None
        return types.Message(id=mid, peer_id=peer, date=at, message=text, out=out, from_id=from_id)

    def visible_pts(self, at=None):
        at = at or now()
        return max([e.pts for e in self.log if e.visible_at <= at], default=0)

    def add_message(self, chat_key, text, at=None, sender=ALICE, out=False):
        """A new message (live). Returns it. Pushes to connected clients."""
        at = at or now()
        message = self._message(chat_key, text, at, sender=sender, out=out)
        if chat_key.startswith("channel:"):
            cid = int(chat_key.split(":")[1])
            log = self.channel_logs[cid]
            log.append(Entry(len(log) + 2, "new", message, visible_at=at, channel=cid))
            self._push(cid)
        else:
            self.log.append(Entry(len(self.log) + 1, "new", message, visible_at=at))
            self._push(None)
        return message

    def edit_message(self, message, text):
        edited = types.Message(id=message.id, peer_id=message.peer_id, date=message.date, message=text,
                               out=message.out, from_id=message.from_id, edit_date=now())
        if isinstance(message.peer_id, types.PeerChannel):
            log = self.channel_logs[message.peer_id.channel_id]
            log.append(Entry(len(log) + 2, "edit", edited, visible_at=now(), channel=message.peer_id.channel_id))
            self._push(message.peer_id.channel_id)
        else:
            self.log.append(Entry(len(self.log) + 1, "edit", edited, visible_at=now()))
            self._push(None)
        return edited

    def delete_messages(self, ids, channel=None):
        if channel:
            log = self.channel_logs[channel]
            log.append(Entry(len(log) + 2, "delete", ids=list(ids), visible_at=now(), channel=channel))
            self._push(channel)
        else:
            self.log.append(Entry(len(self.log) + 1, "delete", ids=list(ids), visible_at=now()))
            self._push(None)

    def _push(self, channel):
        for client in list(self.clients):
            if client.push and client.connected:
                client.push(channel)

    def _entities(self):
        return list(self.users.values()), list(self.chats.values())

    def difference(self, pts):
        at = now()
        if pts < self.too_long_below:
            return types.updates.DifferenceTooLong(pts=self.visible_pts(at))
        pending = [e for e in self.log if e.pts > pts and e.visible_at <= at]
        if not pending:
            return types.updates.DifferenceEmpty(date=at, seq=0)
        batch = pending[:self.slice_size]
        new, other = [], []
        for entry in batch:
            if entry.kind == "new":
                new.append(entry.message)
            elif entry.kind == "edit":
                other.append(types.UpdateEditMessage(message=entry.message, pts=entry.pts, pts_count=1))
            else:
                other.append(types.UpdateDeleteMessages(messages=entry.ids, pts=entry.pts, pts_count=1))
        users, chats = self._entities()
        state = types.updates.State(pts=batch[-1].pts, qts=0, date=at, seq=0, unread_count=0)
        if len(pending) > len(batch):
            return types.updates.DifferenceSlice(new_messages=new, new_encrypted_messages=[], other_updates=other,
                                                 chats=chats, users=users, intermediate_state=state)
        return types.updates.Difference(new_messages=new, new_encrypted_messages=[], other_updates=other,
                                        chats=chats, users=users, state=state)

    def channel_difference(self, channel_id, pts, limit):
        at = now()
        log = self.channel_logs[channel_id]
        pending = [e for e in log if e.pts > pts and e.visible_at <= at]
        if not pending:
            return types.updates.ChannelDifferenceEmpty(pts=pts, final=True)
        batch = pending[:min(limit, self.slice_size)]
        new, other = [], []
        for entry in batch:
            if entry.kind == "new":
                new.append(entry.message)
            elif entry.kind == "edit":
                other.append(types.UpdateEditChannelMessage(message=entry.message, pts=entry.pts, pts_count=1))
            else:
                other.append(types.UpdateDeleteChannelMessages(channel_id=channel_id, messages=entry.ids,
                                                               pts=entry.pts, pts_count=1))
        users, chats = self._entities()
        return types.updates.ChannelDifference(pts=batch[-1].pts, new_messages=new, other_updates=other, chats=chats,
                                               users=users, final=len(pending) == len(batch))

    def dialogs(self):
        at = now()
        result = []
        for uid in (ALICE, BOT, SELF_ID):
            result.append(Dialog(self.users[uid], at))
        result.append(Dialog(self.chats[FAMILY], at))
        for cid in (TEAM, NEWS, BIG):
            visible = [e.pts for e in self.channel_logs[cid] if e.visible_at <= at]
            result.append(Dialog(self.chats[cid], at, channel_pts=max(visible, default=0) or 1, participants=None))
        return result

    def messages(self, chat_key, at=None):
        """The chat's current messages: history plus visible live ones, edits
        applied, deletions removed."""
        at = at or now()
        current = {}
        for message in self.history_seed:
            if _key(message.peer_id) == chat_key:
                current[message.id] = message
        logs = self.log if not chat_key.startswith("channel:") else self.channel_logs[int(chat_key.split(":")[1])]
        for entry in logs:
            if entry.visible_at > at:
                continue
            if entry.kind in ("new", "edit") and _key(entry.message.peer_id) == chat_key:
                current[entry.message.id] = entry.message
            elif entry.kind == "delete":
                for mid in entry.ids:
                    current.pop(mid, None)
        return sorted(current.values(), key=lambda message: message.id, reverse=True)

    def history(self, chat_key, offset_id, limit):
        messages = self.messages(chat_key)
        if offset_id:
            messages = [message for message in messages if message.id < offset_id]
        return messages[:limit]

    def search(self, query, chat_key, limit):
        keys = [chat_key] if chat_key else [f"user:{ALICE}", f"user:{SELF_ID}", f"chat:{FAMILY}", f"channel:{TEAM}",
                                             f"channel:{BIG}"]
        found = []
        for key in keys:
            found.extend(message for message in self.messages(key) if query.lower() in (message.message or "").lower())
        found.sort(key=lambda message: message.date, reverse=True)
        return found[:limit]


def _key(peer):
    if isinstance(peer, types.PeerUser):
        return f"user:{peer.user_id}"
    if isinstance(peer, types.PeerChat):
        return f"chat:{peer.chat_id}"
    return f"channel:{peer.channel_id}"


def _loop_ok():
    return True
