"""Telegram data → outbox events, committed with the progress they cover.

An Ingest collects what one batch of Telegram data means for Rails (chats it
introduces, messages, edits, deletions) and then, in ONE SQLite transaction,
appends those events to the outbox and records the progress the batch covers:
the account's pts/qts/date, a channel's pts, or a chat's backfill cursor
(proposal §5a). Until that transaction commits nothing has advanced, so a
crash replays the same batch from Telegram. Progress is never written
anywhere else: the Telethon session keeps no update state (see
telegram.HouseSession).

Batches are bounded for Rails (app/lib/comms_events.rb): at most MAX_ITEMS
items and about MAX_BYTES of JSON per event.
"""

import json

from telethon.tl import types

from . import convert

MAX_ITEMS = 200
MAX_BYTES = 512 * 1024
MAX_TEXT = 64 * 1024


def _size(item):
    return len(json.dumps(item, separators=(",", ":"), ensure_ascii=False).encode())


def chunks(items, max_items=MAX_ITEMS, max_bytes=MAX_BYTES):
    batch, size = [], 0
    for item in items:
        item_size = _size(item) + 1
        if batch and (len(batch) >= max_items or size + item_size > max_bytes):
            yield batch
            batch, size = [], 0
        batch.append(item)
        size += item_size
    if batch:
        yield batch


def _cut(item):
    for field in ("body", "caption"):
        value = item.get(field)
        if isinstance(value, str) and len(value.encode()) > MAX_TEXT:
            item[field] = value.encode()[:MAX_TEXT].decode(errors="ignore")
    return item


class Ingest:
    def __init__(self, store, ref, self_id, me=None):
        self.store = store
        self.ref = ref
        self.self_id = self_id
        self.entities = {"self": me} if me is not None else {}
        self.new_chats = {}       # chat key -> (chat.upsert item, synced, kind, participants)
        self.messages = []
        self.edits = []
        self.deletions = {}       # chat key -> [message ids]
        self.unresolved = 0
        self.peers = {}           # common-box message id -> chat key, for later deletes
        self.dirty_channels = set()
        self.refresh_dialogs = False
        self.counts = {"messages": 0, "edits": 0, "deletions": 0}

    # -- entities and scope ---------------------------------------------------

    def add_entities(self, users=(), chats=()):
        for entity in list(users) + list(chats):
            key = convert.entity_key(entity)
            if key:
                self.entities[key] = entity
            if isinstance(entity, types.User) and entity.id == self.self_id:
                self.entities["self"] = entity

    def note_chat(self, entity, participants=None, history_from=None, last_activity=None, force=False):
        """Lists a chat for Rails (chat.upsert) and records its scope. Returns
        whether it is synced. Known chats are listed again only when forced
        (a dialog refresh)."""
        key = convert.entity_key(entity)
        known = self.store.chat(self.ref, key)
        if participants is None and known is not None:
            participants = known["participants"]
        kind, synced, _reason = convert.chat_scope(entity, self.self_id, participants)
        if known is None or force or bool(known["synced"]) != synced:
            item = convert.chat_event(entity, self.self_id, last_activity=last_activity,
                                      history_from=history_from, participants=participants)
            self.new_chats[key] = (item, synced, kind, participants)
        return synced

    def synced(self, key):
        if key in self.new_chats:
            return self.new_chats[key][1]
        known = self.store.chat(self.ref, key)
        if known is not None:
            return bool(known["synced"])
        entity = self.entities.get(key)
        if entity is not None:
            return self.note_chat(entity)
        # A peer Telegram sent no entity for: a user or basic group is in
        # scope by kind; an unknown channel is not (its size is unknown).
        if key.startswith("channel:"):
            return False
        kind = "direct" if key.startswith("user:") else "group"
        self.new_chats[key] = ({"provider_chat_id": key, "kind": kind, "sync_state": {"synced": True}}, True, kind, None)
        return True

    # -- content ----------------------------------------------------------------

    def message(self, message):
        if not isinstance(message, types.Message):
            return
        key = convert.peer_key(message.peer_id)
        if key is None or not self.synced(key):
            return
        item = convert.message_event(message, self.entities)
        if item is None:
            return
        self.messages.append(_cut(item))
        if not key.startswith("channel:"):
            self.peers[message.id] = key
        self.counts["messages"] += 1

    def edit(self, message):
        if not isinstance(message, types.Message):
            return
        key = convert.peer_key(message.peer_id)
        if key is None or not self.synced(key):
            return
        item = convert.edit_event(message)
        if item:
            self.edits.append(_cut(item))
            self.counts["edits"] += 1

    def delete_common(self, ids):
        """Telegram's deletes outside channels carry no peer: resolve each id
        through the durable map, or count it as not applied (never guess)."""
        for message_id in ids:
            chat = self.peers.get(message_id) or self.store.peer_of(self.ref, message_id)
            if chat:
                self.deletions.setdefault(chat, []).append(str(message_id))
                self.counts["deletions"] += 1
            else:
                self.unresolved += 1

    def delete_channel(self, channel_id, ids):
        key = f"channel:{channel_id}"
        if not self.synced(key):
            return
        self.deletions.setdefault(key, []).extend(str(i) for i in ids)
        self.counts["deletions"] += len(ids)

    def update(self, update):
        if isinstance(update, (types.UpdateNewMessage, types.UpdateNewChannelMessage)):
            self.message(update.message)
        elif isinstance(update, (types.UpdateEditMessage, types.UpdateEditChannelMessage)):
            self.edit(update.message)
        elif isinstance(update, types.UpdateDeleteMessages):
            self.delete_common(update.messages)
        elif isinstance(update, types.UpdateDeleteChannelMessages):
            self.delete_channel(update.channel_id, update.messages)
        elif isinstance(update, types.UpdateChannelTooLong):
            self.dirty_channels.add(update.channel_id)
        elif isinstance(update, (types.UpdateChannel, types.UpdateChatParticipants)):
            self.refresh_dialogs = True

    def difference(self, diff):
        """updates.Difference / DifferenceSlice / ChannelDifference."""
        self.add_entities(diff.users, diff.chats)
        for message in diff.new_messages:
            self.message(message)
        for update in diff.other_updates:
            self.update(update)

    # -- commit -------------------------------------------------------------------

    def events(self):
        events = []
        for batch in chunks([item for item, *_ in self.new_chats.values()]):
            events.append({"type": "chat.upsert", "chats": batch})
        for batch in chunks(self.messages):
            events.append({"type": "message.upsert", "messages": batch})
        for batch in chunks(self.edits):
            events.append({"type": "message.edit", "messages": batch})
        deletions = []
        for chat, ids in self.deletions.items():
            for start in range(0, len(ids), MAX_ITEMS):
                deletions.append({"chat": chat, "provider_message_ids": ids[start:start + MAX_ITEMS]})
        for index, batch in enumerate(chunks(deletions)):
            event = {"type": "message.delete", "deletions": batch}
            if index == 0 and self.unresolved:
                event["unresolved"] = self.unresolved
            events.append(event)
        if self.unresolved and not deletions:
            events.append({"type": "message.delete", "deletions": [], "unresolved": self.unresolved})
        return events

    def commit(self, progress=None, extra_events=(), after_events=(), label="ingest"):
        """Outbox rows, the peer map, chat scope and `progress(store)` (the
        update state or backfill cursor this batch covers) in one
        transaction. Returns the number of events queued."""
        store, ref = self.store, self.ref
        events = list(extra_events) + self.events() + list(after_events)
        with store.transaction():
            for event in events:
                store.enqueue(ref, event)
            for key, (_item, synced, kind, participants) in self.new_chats.items():
                store.upsert_chat(ref, key, synced, kind, participants)
            for message_id, chat in self.peers.items():
                store.remember_peer(ref, message_id, chat)
            if events:
                store.checkpoint(f"{label}:after_outbox")
            if progress:
                progress(store)
            if events:
                store.checkpoint(f"{label}:after_progress")
        if events:
            store.checkpoint(f"{label}:after_commit")
        return len(events)
