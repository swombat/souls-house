"""The Telegram side, behind a seam the tests replace (fake.py).

`Telegram` is everything the account runtime asks of Telegram; `RealTelegram`
does it with Telethon 1.41.

What Telethon does with update state, and why the connector does not let it
(checked in telethon/client/updates.py and telegrambaseclient.py, 1.41.2):

- Its MessageBox advances pts/qts/date (and each channel's pts) in memory in
  process_updates / apply_difference, *before* the update reaches any event
  handler; handlers then run as separate tasks.
- _save_states_and_entities writes that in-memory state to the session
  (session.set_update_state) every keepalive minute, whenever the entity
  cache fills, and on disconnect, with no regard to whether a handler has
  finished, failed, or was refused.
- With catch_up=True, connect() loads the state back from the session and
  resumes from it.

So with Telethon's own handling, a crash or a refused write (a full outbox)
after the minute tick loses updates for good: the session says they were
seen. Here instead:

- HouseSession persists no update state (set_update_state does nothing,
  get_update_states returns nothing), and catch_up stays off. Telethon's
  in-memory MessageBox still runs (it needs it for pushes such as the QR
  login's UpdateLoginToken), but it is never the checkpoint.
- Pushed updates are only a wake-up. The account runtime runs its own
  updates.getDifference / updates.getChannelDifference from the state in
  the connector's store, and writes the resulting events and the new state
  in one transaction (sync.Ingest.commit).
- flood_sleep_threshold is 0: Telethon would otherwise sleep inside a call
  through any FloodWait under a minute, stalling whatever called it
  (a login, a search). Every FloodWait reaches the caller.
"""

import datetime

from telethon import TelegramClient, events, errors
from telethon.sessions import StringSession
from telethon.tl import functions, types

LOGGED_OUT = (errors.AuthKeyUnregisteredError, errors.SessionRevokedError, errors.SessionExpiredError,
              errors.UserDeactivatedError, errors.UserDeactivatedBanError, errors.AuthKeyDuplicatedError)


def is_logged_out(error):
    return isinstance(error, LOGGED_OUT) or (
        isinstance(error, errors.UnauthorizedError) and not isinstance(error, errors.SessionPasswordNeededError))


def peer_from_key(key):
    kind, _, value = key.partition(":")
    number = int(value)
    if kind == "user":
        return types.PeerUser(number)
    if kind == "chat":
        return types.PeerChat(number)
    if kind == "channel":
        return types.PeerChannel(number)
    raise ValueError("bad chat key")


class HouseSession(StringSession):
    """The auth key and DC, as a string the store seals. No update state:
    the connector's store owns that (see the module docstring)."""

    def set_update_state(self, entity_id, state):
        pass

    def get_update_state(self, entity_id):
        return None

    def get_update_states(self):
        return []


class Dialog:
    """What the runtime needs of one dialog."""

    def __init__(self, entity, date=None, channel_pts=None, participants=None):
        self.entity = entity
        self.date = date
        self.channel_pts = channel_pts
        self.participants = participants


class RealTelegram:
    def __init__(self, api_id, api_hash, session=None):
        self.client = TelegramClient(
            HouseSession(session), api_id, api_hash,
            catch_up=False, flood_sleep_threshold=0, receive_updates=True,
            device_model="souls.house", system_version="connector", app_version="1.0",
            entity_cache_limit=50000,
        )
        self._push = None
        self.client.add_event_handler(self._on_raw, events.Raw())

    async def _on_raw(self, update):
        if self._push is None:
            return
        channel = getattr(update, "channel_id", None)
        message = getattr(update, "message", None)
        if channel is None and message is not None and isinstance(getattr(message, "peer_id", None), types.PeerChannel):
            channel = message.peer_id.channel_id
        self._push(channel)

    def on_push(self, callback):
        """callback(channel_id or None), called for every pushed update."""
        self._push = callback

    async def connect(self):
        await self.client.connect()

    async def disconnect(self):
        await self.client.disconnect()

    def is_connected(self):
        return self.client.is_connected()

    async def is_authorized(self):
        return await self.client.is_user_authorized()

    def session_string(self):
        return self.client.session.save()

    # -- login --------------------------------------------------------------

    async def begin_qr(self):
        return await self.client.qr_login()

    async def password_hint(self):
        password = await self.client(functions.account.GetPasswordRequest())
        return password.hint

    async def sign_in_password(self, password):
        return await self.client.sign_in(password=password)

    async def me(self):
        return await self.client.get_me()

    async def log_out(self):
        return await self.client.log_out()

    # -- sync -----------------------------------------------------------------

    async def get_state(self):
        return await self.client(functions.updates.GetStateRequest())

    async def get_difference(self, pts, date, qts):
        return await self.client(functions.updates.GetDifferenceRequest(
            pts=pts, date=datetime.datetime.fromtimestamp(date, datetime.timezone.utc), qts=qts))

    async def get_channel_difference(self, channel_id, pts, limit=100):
        channel = await self.client.get_input_entity(types.PeerChannel(channel_id))
        return await self.client(functions.updates.GetChannelDifferenceRequest(
            channel=channel, filter=types.ChannelMessagesFilterEmpty(), pts=pts, limit=limit, force=False))

    async def dialogs(self):
        result = []
        async for dialog in self.client.iter_dialogs():
            entity = dialog.entity
            result.append(Dialog(entity, dialog.date, getattr(dialog.dialog, "pts", None),
                                 getattr(entity, "participants_count", None)))
        return result

    async def participants(self, channel_id):
        channel = await self.client.get_input_entity(types.PeerChannel(channel_id))
        full = await self.client(functions.channels.GetFullChannelRequest(channel))
        return full.full_chat.participants_count

    async def history(self, chat_key, offset_id, limit):
        peer = await self.client.get_input_entity(peer_from_key(chat_key))
        result = await self.client(functions.messages.GetHistoryRequest(
            peer=peer, offset_id=offset_id or 0, offset_date=None, add_offset=0, limit=limit,
            max_id=0, min_id=0, hash=0))
        return result.messages, result.users, result.chats

    async def search(self, query, chat_key, limit):
        if chat_key:
            peer = await self.client.get_input_entity(peer_from_key(chat_key))
            result = await self.client(functions.messages.SearchRequest(
                peer=peer, q=query, filter=types.InputMessagesFilterEmpty(), min_date=None, max_date=None,
                offset_id=0, add_offset=0, limit=limit, max_id=0, min_id=0, hash=0))
        else:
            result = await self.client(functions.messages.SearchGlobalRequest(
                q=query, filter=types.InputMessagesFilterEmpty(), min_date=None, max_date=None,
                offset_rate=0, offset_peer=types.InputPeerEmpty(), offset_id=0, limit=limit))
        return result.messages, result.users, result.chats
