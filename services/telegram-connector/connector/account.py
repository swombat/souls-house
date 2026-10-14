"""One Telegram account (one ServiceConnection): login, sync, backfill,
search, logout, and delivery of its outbox to Rails.

Tasks per account, all in the one asyncio loop:

- login    QR (auth.exportLoginToken through Telethon's qr_login), renewed as
           each code expires, then the two-step password if the account has
           one. Or, instead of the QR, the phone number and the code Telegram
           sends to the account's app (auth.sendCode / auth.signIn), the way
           Telegram Desktop signs in on a phone: asking for a code ends the
           QR loop for that attempt. Bound to a login generation (proposal §5).
- sync     the account's own updates.getDifference loop, and getChannelDifference
           for synced supergroups, from the state in the store. Pushes only wake
           it. Events and the state they cover commit together (sync.Ingest).
- backfill the last BACKFILL_DAYS (at most BACKFILL_MAX messages) of each
           synced chat, a bounded page at a time, round robin, with a pause
           between pages; a FloodWait pauses backfill for the whole account.
           It never holds the command lock, so login, logout and search are
           never behind it; live sync is a separate task.
- delivery the outbox to Rails, in order (rails.Deliverer).

Saturation (§5a): when the outbox holds OUTBOX_CAP undelivered events (or the
oldest is older than OUTBOX_MAX_AGE), sync and backfill stop fetching. Nothing
is acknowledged to Telegram and no state moves, so the updates wait at
Telegram; when delivery brings the outbox under OUTBOX_LOW they resume from the
stored state. Rails is told "backlogged" (and "ok" after) out of band.

Logs carry fixed words and a keyed log id, never a connection ref, a name, a
message, a code, a phone number or a password.
"""

import asyncio
import datetime
import hashlib
import hmac
import json
import logging
import re
import time

from telethon import errors
from telethon.tl import types

from . import convert, rails
from .sync import Ingest
from .telegram import is_logged_out

log = logging.getLogger("telegram.account")

DATA_EVENTS = {"chat.upsert", "message.upsert", "message.edit", "message.delete", "sync.checkpoint"}

# What Telegram's auth.sentCode says about where the code went, for the page
# ("Telegram sent a code to your Telegram app"). The connector's seam
# (telegram.py) reports one of these words.
CODE_DELIVERIES = ("app", "sms", "call", "fragment", "email", "other")
PHONE_SEPARATORS = re.compile(r"[\s().\-]")


def normalize_phone(phone):
    """An international number (+ or 00, then 7–15 digits) as the digits
    Telegram takes, or None. Never logged."""
    if not isinstance(phone, str) or len(phone) > 40:
        return None
    phone = PHONE_SEPARATORS.sub("", phone)
    if phone.startswith("+"):
        phone = phone[1:]
    elif phone.startswith("00"):
        phone = phone[2:]
    else:
        return None
    if not phone.isdigit() or not 7 <= len(phone) <= 15 or phone.startswith("0"):
        return None
    return phone


class Settings:
    outbox_cap = 10_000
    outbox_low = 5_000
    outbox_max_age = 7 * 86400
    backfill_days = 30
    backfill_max = 500
    backfill_page = 100
    backfill_pause = 0.5
    poll_interval = 60.0
    channel_poll_interval = 300.0
    dialog_refresh = 1800.0
    checkpoint_interval = 300.0
    login_window = 600.0
    password_window = 600.0
    qr_max_lifetime = 290.0
    retry_max = 30.0
    logout_timeout = 20.0
    delivery_idle = 30.0

    def __init__(self, **overrides):
        for name, value in overrides.items():
            if not hasattr(self, name):
                raise AttributeError(name)
            setattr(self, name, value)


class Refused(Exception):
    def __init__(self, code, status=409):
        super().__init__(code)
        self.code = code
        self.status = status


def now_iso(moment=None):
    moment = moment or datetime.datetime.now(datetime.timezone.utc)
    return moment.astimezone(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def log_id(key, ref):
    return hmac.new(key, ref.encode(), hashlib.sha256).hexdigest()[:10]


class Account:
    def __init__(self, ref, store, factory, post, settings=None, log_key=b"", on_gone=None):
        self.ref = ref
        self.store = store
        self.factory = factory          # factory(session_string or None) -> Telegram
        self.post = post                # post(path, body, headers) -> (status, json)
        self.settings = settings or Settings()
        self.id = log_id(log_key, ref)
        self.on_gone = on_gone
        self.lock = asyncio.Lock()
        self.client = None
        self.me = None
        self.tasks = {}
        self.deliverer = rails.Deliverer(store, ref, post)
        self.delivery_wake = asyncio.Event()
        self.sync_wake = asyncio.Event()
        self.backfill_wake = asyncio.Event()
        self.password_done = asyncio.Event()
        self.awaiting_password = None
        # The phone-number path of the current attempt: {"generation",
        # "phone", "hash"} in memory only (never stored, queued or logged).
        self.phone_login = None
        self.code_done = asyncio.Event()
        # Where the attempt is: connecting | qr | code | password | finishing.
        self.login_phase = None
        self.login_ready = asyncio.Event()
        self.dirty_channels = set()
        self.backlogged = False
        self.flood_until = 0.0
        # Bumped whenever a gap resets history cursors: a history page that
        # was in flight across a reset is dropped, not committed over it.
        self.backfill_resets = 0
        self.closed = False

    # -- helpers ----------------------------------------------------------------

    def _row(self):
        return self.store.connection(self.ref)

    def _spawn(self, name, coro):
        task = asyncio.get_running_loop().create_task(coro, name=f"{name}")
        self.tasks[name] = task
        task.add_done_callback(lambda t, n=name: self._task_done(n, t))
        return task

    def _task_done(self, name, task):
        if self.tasks.get(name) is task:
            del self.tasks[name]
        if not task.cancelled() and task.exception() is not None:
            log.error("task ended with an error: account=%s task=%s error=%s", self.id, name,
                      type(task.exception()).__name__)

    async def _cancel(self, *names):
        current = asyncio.current_task()
        tasks = [self.tasks.get(name) for name in names]
        tasks = [task for task in tasks if task is not None and task is not current]
        for task in tasks:
            task.cancel()
        for task in tasks:
            try:
                await task
            except BaseException:
                pass

    async def _drop_client(self):
        client, self.client = self.client, None
        self.phone_login = None
        if client is not None:
            try:
                await asyncio.wait_for(client.disconnect(), 10)
            except BaseException:
                pass

    def _enqueue(self, *events):
        with self.store.transaction():
            for event in events:
                self.store.enqueue(self.ref, event)
        self.delivery_wake.set()

    def ensure_delivery(self):
        if "delivery" not in self.tasks and not self.closed:
            self._spawn("delivery", self._delivery_loop())

    # -- commands ------------------------------------------------------------------

    async def start_login(self, generation, secret, version):
        async with self.lock:
            row = self.store.ensure_connection(self.ref)
            if not isinstance(generation, int) or generation <= row["generation"]:
                raise Refused("stale_generation")
            if not isinstance(version, int) or version < row["secret_version"]:
                raise Refused("stale_secret_version")
            await self._cancel("login", "sync", "backfill", "resume")
            await self._discard_session()
            # Rails refuses the old session's chats and messages while the
            # new attempt is pairing; they wait in the carryover.
            self.store.set_aside_pending(self.ref, lambda event: event.get("type") in DATA_EVENTS)
            with self.store.transaction():
                self.store.set_callback_secret(self.ref, secret, version)
                self.store.wipe_sync_state(self.ref)
                self.store.update_connection(self.ref, generation=generation, status="logging_in")
            self.awaiting_password = None
            self.password_done = asyncio.Event()
            self.phone_login = None
            self.code_done = asyncio.Event()
            self.login_phase = "connecting"
            self.login_ready = asyncio.Event()
            self._spawn("login", self._login(generation))
            self.ensure_delivery()
            self.delivery_wake.set()
            log.info("login started: account=%s", self.id)
            return {"status": "pairing", "generation": generation}

    async def cancel_login(self, generation):
        async with self.lock:
            row = self._row()
            if row is None:
                return {"status": "cancelled"}
            if not isinstance(generation, int) or generation < row["generation"]:
                raise Refused("stale_generation")
            await self._cancel("login", "sync", "backfill", "resume")
            await self._discard_session()
            with self.store.transaction():
                self.store.wipe_sync_state(self.ref)
                self.store.update_connection(self.ref, generation=generation, status="cancelled")
            self.awaiting_password = None
            self.phone_login = None
            self.login_phase = None
            log.info("login cancelled: account=%s", self.id)
            return {"status": "cancelled"}

    async def request_code(self, generation, phone):
        """Sign in with the phone number instead of the QR: Telegram sends a
        code to the account's app (or by SMS). Only for the current attempt
        while it is logging in; the QR loop for that attempt stops (no more
        login.qr). The number and Telegram's phone_code_hash stay in memory
        for submit_code; neither is stored, queued or logged. Asking again
        resends (Telethon's send_code_request uses auth.resendCode for a
        number it already sent to) or, for another number, starts over.
        Returns {"outcome": code_sent|phone_invalid|phone_banned|unsupported|
        password_required|accepted|flood_wait|failed}."""
        async with self.lock:
            row = self._row()
            if (row is None or generation != row["generation"] or row["status"] != "logging_in"
                    or self.awaiting_password is not None):
                raise Refused("not_logging_in")
            if self.login_phase == "connecting":
                try:
                    await asyncio.wait_for(self.login_ready.wait(), 15)
                except asyncio.TimeoutError:
                    pass
            if self.login_phase not in ("qr", "code") or self.client is None:
                raise Refused("not_logging_in")
            digits = normalize_phone(phone)
            phone = None  # noqa: F841 (drop the reference at once)
            if digits is None:
                return {"outcome": "phone_invalid"}
            if self.login_phase == "qr":
                # The QR path ends for this attempt; the phone path gets its
                # own window.
                await self._cancel("login", *[name for name in self.tasks if name.startswith("qr-")])
                self.login_phase = "code"
                self.phone_login = {"generation": generation, "phone": None, "hash": None}
                self.code_done = asyncio.Event()
                self._spawn("login", self._code_window(generation))
                if await self._authorized_meanwhile():
                    # The QR was scanned just as the code was asked for.
                    user = await self.client.me()
                    self._code_finished()
                    await self._finish_login(user, generation)
                    return {"outcome": "accepted"}
            try:
                sent = await self.client.send_code(digits)
            except errors.SessionPasswordNeededError:
                # A QR scan raced the request and reached the password step.
                self._code_finished()
                self._begin_password_step(generation)
                return {"outcome": "password_required"}
            except errors.PhoneNumberInvalidError:
                return {"outcome": "phone_invalid"}
            except errors.PhoneNumberBannedError:
                return {"outcome": "phone_banned"}
            except errors.FloodWaitError as error:
                return {"outcome": "flood_wait", "retry_after": error.seconds}
            except errors.PhoneNumberFloodError:
                return {"outcome": "flood_wait"}
            except Exception as error:
                log.warning("code request failed: account=%s error=%s", self.id, type(error).__name__)
                return {"outcome": "failed"}
            delivery = sent.get("delivery")
            if delivery not in CODE_DELIVERIES or not sent.get("hash"):
                # Telegram wants something a third-party app cannot do here
                # (set up a login email, pay): the QR still works.
                self.phone_login.update(phone=None, hash=None)
                return {"outcome": "unsupported"}
            self.phone_login.update(phone=digits, hash=sent["hash"])
            digits = None
            state = {"delivery": delivery}
            for key in ("length", "next_delivery", "timeout"):
                value = sent.get(key)
                if value is not None:
                    state[key] = value
            self._enqueue({"type": "login.code_sent", "generation": generation, **state})
            log.info("login code sent: account=%s delivery=%s", self.id, delivery)
            return {"outcome": "code_sent", **state}

    async def submit_code(self, generation, code):
        """The code Telegram sent, for the attempt that asked for it. Used
        for auth.signIn and dropped: never stored, queued or logged. A
        two-step account goes on to the password step. Returns {"outcome":
        accepted|password_required|code_invalid|code_expired|
        phone_unregistered|flood_wait|failed}."""
        async with self.lock:
            row = self._row()
            pending = self.phone_login
            if (row is None or generation != row["generation"] or pending is None
                    or pending["generation"] != generation or self.client is None
                    or self.awaiting_password is not None):
                raise Refused("not_waiting_for_code")
            if pending["hash"] is None:
                return {"outcome": "code_expired"}
            try:
                user = await self.client.sign_in_code(pending["phone"], code, pending["hash"])
            except errors.SessionPasswordNeededError:
                self._code_finished()
                self._begin_password_step(generation)
                return {"outcome": "password_required"}
            except (errors.PhoneCodeInvalidError, errors.PhoneCodeEmptyError):
                return {"outcome": "code_invalid"}
            except errors.PhoneCodeExpiredError:
                pending["hash"] = None
                return {"outcome": "code_expired"}
            except errors.PhoneNumberUnoccupiedError:
                return {"outcome": "phone_unregistered"}
            except errors.FloodWaitError as error:
                return {"outcome": "flood_wait", "retry_after": error.seconds}
            except Exception as error:
                log.warning("code check failed: account=%s error=%s", self.id, type(error).__name__)
                return {"outcome": "failed"}
            finally:
                code = None  # noqa: F841 (drop the reference at once)
            self._code_finished()
            await self._finish_login(user, generation)
            return {"outcome": "accepted"}

    async def submit_password(self, generation, password):
        """The password is used for SRP and dropped: never stored, queued or
        logged. Returns {"outcome": accepted|password_invalid|flood_wait|failed}."""
        async with self.lock:
            row = self._row()
            if row is None or generation != row["generation"] or self.awaiting_password != generation or not self.client:
                raise Refused("not_waiting_for_password")
            try:
                user = await self.client.sign_in_password(password)
            except errors.PasswordHashInvalidError:
                return {"outcome": "password_invalid"}
            except errors.FloodWaitError as error:
                return {"outcome": "flood_wait", "retry_after": error.seconds}
            except Exception as error:
                log.warning("password check failed: account=%s error=%s", self.id, type(error).__name__)
                return {"outcome": "failed"}
            finally:
                password = None  # noqa: F841 (drop the reference at once)
            self.awaiting_password = None
            await self._finish_login(user, generation)
            self.password_done.set()
            return {"outcome": "accepted"}

    async def logout(self):
        """auth.logOut at Telegram (so the session leaves Active Sessions),
        then the connection's store rows go. Idempotent."""
        async with self.lock:
            await self._shutdown(log_out=True)
            log.info("logged out: account=%s", self.id)
            return {"status": "logged_out"}

    async def search(self, query, chat, limit, scope):
        row = self._row()
        if row is None or row["status"] != "connected" or self.client is None:
            raise Refused("not_connected")
        if not isinstance(query, str) or not query.strip() or len(query) > 200:
            raise Refused("bad_query", 422)
        limit = max(1, min(int(limit or 20), 50))
        if scope not in ("synced", "all_dialogs"):
            raise Refused("bad_scope", 422)
        synced = {c["chat"] for c in self.store.chats(self.ref, synced=True)}
        if chat is not None:
            if not isinstance(chat, str) or self.store.chat(self.ref, chat) is None:
                raise Refused("unknown_chat", 404)
            if scope == "synced" and chat not in synced:
                raise Refused("chat_not_synced", 403)
        coverage = {"scope": scope}
        if chat:
            coverage["chat"] = chat
        elif scope == "synced":
            coverage["chats"] = len(synced)
        try:
            # A global search is filtered to synced chats afterwards, so ask
            # for more than the limit.
            fetch = limit if chat or scope == "all_dialogs" else min(limit * 3, 100)
            messages, users, chats = await self.client.search(query, chat, fetch)
        except errors.FloodWaitError as error:
            return {"coverage": coverage, "results": [], "retry_after": error.seconds}
        entities = {}
        for entity in list(users) + list(chats):
            key = convert.entity_key(entity)
            if key:
                entities[key] = entity
        if self.me is not None:
            entities["self"] = self.me
        results = []
        for message in messages:
            item = convert.message_event(message, entities)
            if item is None:
                continue
            if scope == "synced" and item["chat"] not in synced:
                continue
            results.append(item)
            if len(results) >= limit:
                break
        return {"coverage": coverage, "results": results}

    # -- login ------------------------------------------------------------------------

    def _post_qr(self, generation, qr):
        issued = datetime.datetime.now(datetime.timezone.utc)
        expires = qr.expires
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=datetime.timezone.utc)
        cap = issued + datetime.timedelta(seconds=self.settings.qr_max_lifetime)
        expires = min(expires, cap)
        event = {"type": "login.qr", "generation": generation, "code": qr.url,
                 "issued_at": now_iso(issued), "expires_at": now_iso(expires)}

        async def send():
            # Not stored: a code is worth sending only until it expires.
            while datetime.datetime.now(datetime.timezone.utc) < expires:
                status = await rails.post_event(self.store, self.ref, self.post, event)
                if status is not None and status < 500:
                    return
                await asyncio.sleep(1)

        self.qr_count = getattr(self, "qr_count", 0) + 1
        self._spawn(f"qr-{self.qr_count}", send())

    async def _login(self, generation):
        settings = self.settings
        loop = asyncio.get_running_loop()
        try:
            self.client = self.factory(None)
            await self.client.connect()
            qr = await self.client.begin_qr()
            self.login_phase = "qr"
            self.login_ready.set()
            deadline = loop.time() + settings.login_window
            while True:
                self._post_qr(generation, qr)
                expires = qr.expires if qr.expires.tzinfo else qr.expires.replace(tzinfo=datetime.timezone.utc)
                remaining = (expires - datetime.datetime.now(datetime.timezone.utc)).total_seconds()
                try:
                    user = await qr.wait(timeout=max(1.0, min(remaining, settings.qr_max_lifetime)))
                    self.login_phase = "finishing"
                    break
                except asyncio.TimeoutError:
                    if loop.time() >= deadline:
                        await self._login_failed(generation, "expired")
                        return
                    await qr.recreate()
        except errors.SessionPasswordNeededError:
            self.login_phase = "password"
            await self._password_step(generation)
            return
        except errors.FloodWaitError as error:
            await self._login_failed(generation, "flood_wait", error.seconds)
            return
        except asyncio.CancelledError:
            raise
        except Exception as error:
            log.warning("login failed: account=%s error=%s", self.id, type(error).__name__)
            await self._login_failed(generation, "failed")
            return
        async with self.lock:
            if self._row()["generation"] != generation:
                return
            await self._finish_login(user, generation)

    async def _authorized_meanwhile(self):
        try:
            return await asyncio.wait_for(self.client.is_authorized(), 10)
        except Exception:
            return False

    async def _code_window(self, generation):
        """The phone path's own deadline (the QR loop's went with it)."""
        try:
            await asyncio.wait_for(self.code_done.wait(), self.settings.login_window)
        except asyncio.TimeoutError:
            async with self.lock:
                row = self._row()
                if self.phone_login is not None and row is not None and row["generation"] == generation:
                    await self._login_failed(generation, "expired")

    def _code_finished(self):
        self.phone_login = None
        self.code_done.set()

    def _begin_password_step(self, generation):
        self.login_phase = "password"
        self.awaiting_password = generation
        self._spawn("login", self._password_step(generation))

    async def _password_step(self, generation):
        try:
            hint = await self.client.password_hint()
        except Exception:
            hint = None
        event = {"type": "login.password_required", "generation": generation}
        if hint:
            event["hint"] = hint[:200]
        self._enqueue(event)
        self.awaiting_password = generation
        try:
            await asyncio.wait_for(self.password_done.wait(), self.settings.password_window)
        except asyncio.TimeoutError:
            async with self.lock:
                if self.awaiting_password == generation:
                    self.awaiting_password = None
                    await self._login_failed(generation, "expired")

    async def _login_failed(self, generation, code, retry_after=None):
        event = {"type": "login.failed", "generation": generation, "code": code}
        if retry_after:
            event["retry_after"] = int(retry_after)
        self.login_phase = None
        self.login_ready.set()
        await self._drop_client()
        with self.store.transaction():
            self.store.enqueue(self.ref, event)
            self.store.wipe_sync_state(self.ref)
            self.store.update_connection(self.ref, status="failed")
        self.delivery_wake.set()
        log.info("login failed: account=%s code=%s", self.id, code)

    async def _finish_login(self, user, generation):
        self.login_phase = "finishing"
        state = await self.client.get_state()
        self.me = user
        identity = {"user_id": str(user.id), "display_name": convert.display_name(user)}
        if getattr(user, "username", None):
            identity["username"] = user.username
        identity = {key: value for key, value in identity.items() if value}
        with self.store.transaction():
            self.store.set_session(self.ref, self.client.session_string())
            self.store.update_connection(
                self.ref, status="connected", self_id=user.id,
                pts=state.pts, qts=state.qts, date=int(state.date.timestamp()))
            self.store.enqueue(self.ref, {"type": "status.changed", "status": "connected",
                                          "generation": generation, "identity": identity})
            self.store.take_carryover(self.ref)
        self.delivery_wake.set()
        log.info("connected: account=%s", self.id)
        self._start_runtime()

    async def _discard_session(self):
        """Before a new attempt: the old session (if any) is logged out at
        Telegram, best effort, so it does not linger in Active Sessions."""
        row = self._row()
        client = self.client
        if client is None and row is not None and row["session"] is not None:
            try:
                client = self.factory(self.store.session(self.ref))
                await asyncio.wait_for(client.connect(), 10)
            except BaseException:
                client = None
        if client is not None:
            try:
                if await asyncio.wait_for(client.is_authorized(), 10):
                    await asyncio.wait_for(client.log_out(), self.settings.logout_timeout)
            except BaseException:
                pass
            self.client = client
        await self._drop_client()

    # -- running ----------------------------------------------------------------------

    def _start_runtime(self):
        self.client.on_push(self._on_push)
        self._spawn("sync", self._sync_loop())
        self._spawn("backfill", self._backfill_loop())

    def _on_push(self, channel_id):
        if channel_id is not None:
            self.dirty_channels.add(channel_id)
        self.sync_wake.set()

    async def resume(self):
        """At boot: a connection with a session reconnects and syncs from
        its stored state; one without just delivers what it holds."""
        self.ensure_delivery()
        row = self._row()
        if row is None or row["status"] != "connected" or row["session"] is None:
            return
        self._spawn("resume", self._resume())

    async def _resume(self):
        delay = 1.0
        while True:
            try:
                async with self.lock:
                    row = self._row()
                    if row is None or row["status"] != "connected":
                        return
                    self.client = self.factory(self.store.session(self.ref))
                    await self.client.connect()
                    if not await self.client.is_authorized():
                        await self._logged_out(cancel=False)
                        return
                    self.me = await self.client.me()
                    self._start_runtime()
                    log.info("resumed: account=%s", self.id)
                    return
            except asyncio.CancelledError:
                raise
            except Exception as error:
                if is_logged_out(error):
                    async with self.lock:
                        await self._logged_out(cancel=False)
                    return
                log.warning("resume failed: account=%s error=%s", self.id, type(error).__name__)
                await self._drop_client()
                await asyncio.sleep(delay)
                delay = min(delay * 2, self.settings.retry_max)

    async def _logged_out(self, cancel=True):
        """Telegram ended the session (terminated from the phone, or expired):
        Rails is told, the session goes, and sign-in has to start again."""
        if cancel:
            await self._cancel("sync", "backfill")
        await self._drop_client()
        row = self._row()
        with self.store.transaction():
            self.store.wipe_sync_state(self.ref)
            self.store.update_connection(self.ref, status="logged_out")
            self.store.enqueue(self.ref, {"type": "status.changed", "status": "logged_out",
                                          "generation": row["generation"]})
        self.delivery_wake.set()
        log.info("logged out by Telegram: account=%s", self.id)

    def _over_cap(self):
        settings = self.settings
        pending = self.store.pending_count(self.ref)
        if self.backlogged:
            return pending >= settings.outbox_low
        age = self.store.oldest_pending_age(self.ref) or 0
        return pending >= settings.outbox_cap or age >= settings.outbox_max_age

    async def _availability(self, state, reason=None):
        event = {"type": "connector.availability", "state": state, "since": now_iso()}
        if reason:
            event["reason"] = reason
        await rails.post_event(self.store, self.ref, self.post, event)

    async def wait_capacity(self):
        """Blocks while the outbox is saturated. Fetches nothing meanwhile."""
        while self._over_cap():
            if not self.backlogged:
                self.backlogged = True
                log.warning("outbox saturated; ingestion paused: account=%s", self.id)
                self._spawn("availability", self._availability("backlogged", "outbox_full"))
            await asyncio.sleep(1)
        if self.backlogged:
            self.backlogged = False
            log.info("outbox drained; ingestion resumed: account=%s", self.id)
            self._spawn("availability", self._availability("ok"))

    async def _sync_loop(self):
        settings = self.settings
        loop = asyncio.get_running_loop()
        delay = 1.0
        first = True
        last_dialogs = last_channels = last_checkpoint = loop.time()
        # The start of the last pass whose account difference and channel
        # differences all ran to the end: the only coverage a checkpoint may
        # claim. A pass cut short by saturation establishes nothing.
        established = published = None
        while True:
            try:
                await self.wait_capacity()
                if first or loop.time() - last_dialogs >= settings.dialog_refresh:
                    await self._refresh_dialogs(force=first)
                    first, last_dialogs = False, loop.time()
                started = time.time()
                complete = await self.account_difference()
                if loop.time() - last_channels >= settings.channel_poll_interval:
                    self.dirty_channels.update(self.store.channel_pts(self.ref))
                    last_channels = loop.time()
                while self.dirty_channels:
                    await self.wait_capacity()
                    complete = await self.channel_difference(self.dirty_channels.pop()) and complete
                if complete:
                    established = started
                if loop.time() - last_checkpoint >= settings.checkpoint_interval:
                    fresh = established if established is not None and established != published else None
                    self._checkpoint(fresh)
                    if fresh is not None:
                        published, last_checkpoint = fresh, loop.time()
                delay = 1.0
            except asyncio.CancelledError:
                raise
            except errors.FloodWaitError as error:
                log.warning("sync flood wait: account=%s seconds=%s", self.id, error.seconds)
                self.flood_until = max(self.flood_until, loop.time() + error.seconds)
                await asyncio.sleep(error.seconds)
                continue
            except Exception as error:
                if is_logged_out(error):
                    async with self.lock:
                        await self._logged_out()
                    return
                log.warning("sync failed: account=%s error=%s", self.id, type(error).__name__)
                await asyncio.sleep(delay)
                delay = min(delay * 2, settings.retry_max)
                continue
            try:
                await asyncio.wait_for(self.sync_wake.wait(), settings.poll_interval)
            except asyncio.TimeoutError:
                pass
            self.sync_wake.clear()

    def _ingest(self):
        return Ingest(self.store, self.ref, self._row()["self_id"], self.me)

    def _ingested(self, ingest):
        """After a live commit: delivery has rows, and a synced chat seen for
        the first time has history waiting for the backfill worker."""
        self.delivery_wake.set()
        if ingest.new_synced_chats:
            self.backfill_wake.set()

    def _history_reset(self):
        self.backfill_resets += 1
        self.backfill_wake.set()

    async def _refresh_dialogs(self, force):
        dialogs = await self.client.dialogs()
        ingest = self._ingest()
        known_channels = self.store.channel_pts(self.ref)
        new_channels = {}
        for dialog in dialogs:
            entity = dialog.entity
            participants = dialog.participants
            key = convert.entity_key(entity)
            if key is None:
                continue
            known = self.store.chat(self.ref, key)
            if (isinstance(entity, types.Channel) and entity.megagroup and participants is None
                    and (known is None or known["participants"] is None)):
                try:
                    participants = await self.client.participants(entity.id)
                except errors.FloodWaitError:
                    participants = None
                except Exception:
                    participants = None
            synced = ingest.note_chat(entity, participants, last_activity=dialog.date, force=force)
            if synced and isinstance(entity, types.Channel) and entity.id not in known_channels and dialog.channel_pts:
                new_channels[entity.id] = dialog.channel_pts
        if ingest.new_chats or new_channels:
            def progress(store):
                for channel_id, pts in new_channels.items():
                    store.set_channel_pts(self.ref, channel_id, pts)
            ingest.commit(progress, label="dialogs")
            self.delivery_wake.set()
            self.backfill_wake.set()

    async def account_difference(self):
        """getDifference from the stored state until Telegram has nothing
        more, one committed batch per answer. Returns True when it reached
        the end, False when saturation stopped it with Telegram holding more
        (the stored state is then behind Telegram's)."""
        while True:
            if self._over_cap():
                return False
            row = self._row()
            diff = await self.client.get_difference(row["pts"], row["date"], row["qts"])
            ingest = self._ingest()
            if isinstance(diff, types.updates.DifferenceEmpty):
                date = int(diff.date.timestamp())
                if date != row["date"]:
                    ingest.commit(lambda store: store.update_connection(self.ref, date=date), label="live")
                return True
            if isinstance(diff, types.updates.DifferenceTooLong):
                # Telegram will not replay the gap: take its pts and fetch the
                # synced chats' recent history again (§5a fallback).
                def too_long(store, pts=diff.pts):
                    store.update_connection(self.ref, pts=pts)
                    store.restart_backfill(self.ref, [c["chat"] for c in store.chats(self.ref, synced=True)
                                                      if not c["chat"].startswith("channel:")])
                ingest.commit(too_long, label="live")
                self._history_reset()
                log.warning("difference too long; history refetched: account=%s", self.id)
                continue
            state = diff.state if isinstance(diff, types.updates.Difference) else diff.intermediate_state
            ingest.difference(diff)

            def progress(store, state=state):
                store.update_connection(self.ref, pts=state.pts, qts=state.qts, date=int(state.date.timestamp()))
            ingest.commit(progress, label="live")
            self.dirty_channels.update(ingest.dirty_channels)
            self._ingested(ingest)
            if isinstance(diff, types.updates.Difference):
                return True

    async def channel_difference(self, channel_id):
        """Like account_difference, for one channel. Returns False when
        saturation stopped it (the channel stays dirty)."""
        pts = self.store.channel_pts(self.ref).get(channel_id)
        if pts is None:
            return True
        while True:
            if self._over_cap():
                self.dirty_channels.add(channel_id)
                return False
            try:
                diff = await self.client.get_channel_difference(channel_id, pts)
            except (errors.ChannelPrivateError, errors.ChannelInvalidError):
                with self.store.transaction():
                    self.store.db.execute("DELETE FROM channels WHERE ref = ? AND channel_id = ?", (self.ref, channel_id))
                return True
            ingest = self._ingest()
            if isinstance(diff, types.updates.ChannelDifferenceEmpty):
                if diff.pts != pts:
                    ingest.commit(lambda store, p=diff.pts: store.set_channel_pts(self.ref, channel_id, p), label="channel")
                return True
            if isinstance(diff, types.updates.ChannelDifferenceTooLong):
                ingest.add_entities(diff.users, diff.chats)
                for message in diff.messages:
                    ingest.message(message)
                new_pts = diff.dialog.pts

                def too_long(store, p=new_pts):
                    store.set_channel_pts(self.ref, channel_id, p)
                    store.restart_backfill(self.ref, [f"channel:{channel_id}"])
                ingest.commit(too_long, label="channel")
                self._history_reset()
                self._ingested(ingest)
                return True
            ingest.difference(diff)
            ingest.commit(lambda store, p=diff.pts: store.set_channel_pts(self.ref, channel_id, p), label="channel")
            self._ingested(ingest)
            pts = diff.pts
            if diff.final:
                return True

    def _checkpoint(self, through):
        """Every synced, backfilled chat is in the outbox up to `through` (the
        start of a pass whose differences all ran to the end; None when no
        new one has), and this event is queued after those rows, so Rails
        never shows a checkpoint ahead of its data."""
        if through is None:
            return
        chats = [{"provider_chat_id": c["chat"], "synced_through": now_iso(
                    datetime.datetime.fromtimestamp(through, datetime.timezone.utc))}
                 for c in self.store.chats(self.ref, synced=True) if c["backfill_done"]]
        if not chats:
            return
        with self.store.transaction():
            for start in range(0, len(chats), 200):
                self.store.enqueue(self.ref, {"type": "sync.checkpoint", "chats": chats[start:start + 200]})
        self.delivery_wake.set()

    # -- backfill ----------------------------------------------------------------------

    async def _backfill_loop(self):
        settings = self.settings
        loop = asyncio.get_running_loop()
        while True:
            try:
                await self.wait_capacity()
                if loop.time() < self.flood_until:
                    await asyncio.sleep(self.flood_until - loop.time())
                    continue
                chats = self.store.pending_backfill(self.ref)
                if not chats:
                    self.backfill_wake.clear()
                    await self.backfill_wake.wait()
                    continue
                for chat in chats:
                    await self.wait_capacity()
                    if loop.time() < self.flood_until:
                        break
                    await self.backfill_page(chat["chat"])
                    await asyncio.sleep(settings.backfill_pause)
            except asyncio.CancelledError:
                raise
            except errors.FloodWaitError as error:
                # Account-level: every backfill page waits it out; live sync,
                # login, logout and search do not.
                log.warning("backfill flood wait: account=%s seconds=%s", self.id, error.seconds)
                self.flood_until = max(self.flood_until, loop.time() + error.seconds)
            except Exception as error:
                if is_logged_out(error):
                    self.sync_wake.set()  # the sync loop handles it
                    return
                log.warning("backfill failed: account=%s error=%s", self.id, type(error).__name__)
                await asyncio.sleep(5)

    async def backfill_page(self, chat_key):
        """One page of one chat's history, newest first, committed with the
        chat's backfill cursor. A page whose request was in flight while a
        gap reset the cursors is dropped: the next page starts from the
        reset (newest) end, so the gap's messages are fetched."""
        settings = self.settings
        chat = self.store.chat(self.ref, chat_key)
        if chat is None or chat["backfill_done"] or not chat["synced"]:
            return
        resets = self.backfill_resets
        messages, users, chats = await self.client.history(chat_key, chat["backfill_offset"], settings.backfill_page)
        if resets != self.backfill_resets:
            log.info("history page dropped after a gap reset: account=%s", self.id)
            return
        chat = self.store.chat(self.ref, chat_key)
        if chat is None or chat["backfill_done"] or not chat["synced"]:
            return
        cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=settings.backfill_days)
        room = settings.backfill_max - chat["backfill_count"]
        keep = []
        reached_cutoff = capped = False
        for message in messages:
            date = message.date if message.date.tzinfo else message.date.replace(tzinfo=datetime.timezone.utc)
            if date < cutoff:
                reached_cutoff = True
                break
            if len(keep) >= room:
                capped = True
                break
            keep.append(message)
        if not reached_cutoff and chat["backfill_count"] + len(keep) >= settings.backfill_max:
            capped = True
        done = len(messages) < settings.backfill_page or reached_cutoff or capped
        offset = min((m.id for m in messages), default=chat["backfill_offset"])
        ingest = self._ingest()
        ingest.add_entities(users, chats)
        for message in keep:
            ingest.message(message)
        # The oldest message kept so far, carried across pages in the chat's
        # history_from column (published to Rails only when done).
        oldest = convert.iso(keep[-1].date) if keep else chat["history_from"]
        history_from = oldest
        after = []
        if done:
            # history_from: how far back this chat's synced history reaches.
            # The window when the cutoff ended it, or when the chat's whole
            # history was shorter (nothing before its oldest message); only
            # as far as the oldest message kept when the count cap ended it
            # (never more than what was fetched).
            if reached_cutoff:
                history_from = convert.iso(cutoff)
            elif capped:
                history_from = oldest or now_iso()
            else:
                history_from = oldest or convert.iso(cutoff)  # the chat's whole history
            after.append({"type": "chat.upsert", "chats": [
                {"provider_chat_id": chat_key, "sync_state": {"synced": True, "history_from": history_from}}]})
        count = chat["backfill_count"] + len(keep)

        def progress(store):
            store.set_backfill(self.ref, chat_key, offset, count, done, history_from)
        ingest.commit(progress, after_events=after, label="backfill")
        self.delivery_wake.set()

    # -- delivery ----------------------------------------------------------------------

    async def _delivery_loop(self):
        delay = 1.0
        while not self.closed:
            self.delivery_wake.clear()
            try:
                outcome, _count = await self.deliverer.run_once()
            except asyncio.CancelledError:
                raise
            except Exception as error:
                log.warning("delivery error: account=%s error=%s", self.id, type(error).__name__)
                outcome = rails.Outcome.FAILED
            if outcome is rails.Outcome.REVOKED:
                log.info("Rails says the connection is revoked; deleting it: account=%s", self.id)
                self._spawn("revoke", self._revoked())
                return
            if outcome is rails.Outcome.FAILED:
                await asyncio.sleep(delay)
                delay = min(delay * 2, self.settings.retry_max)
                continue
            delay = 1.0
            try:
                await asyncio.wait_for(self.delivery_wake.wait(), self.settings.delivery_idle)
            except asyncio.TimeoutError:
                pass

    async def _revoked(self):
        async with self.lock:
            await self._shutdown(log_out=True)

    async def _shutdown(self, log_out):
        self.closed = True
        await self._cancel("login", "sync", "backfill", "resume", "delivery")
        if log_out:
            await self._discard_session()
        else:
            await self._drop_client()
        self.store.delete_connection(self.ref)
        if self.on_gone:
            self.on_gone(self.ref)

    async def close(self):
        """Process shutdown: stop everything, keep the store."""
        self.closed = True
        await self._cancel(*list(self.tasks))
        await self._drop_client()
