"""Telegram objects → the event shapes Rails accepts (app/lib/comms_events.rb).

Chat ids are typed peers: user:<id>, chat:<id>, channel:<id> (proposal §7).
Access hashes never leave the connector.

Scope (§7): DMs, Saved Messages, basic groups and supergroups of at most
SMALL_GROUP members are synced. Bots and broadcast channels are listed but
not synced, with a reason.
"""

from datetime import timezone

from telethon.tl import types

SMALL_GROUP = 30


def peer_key(peer):
    if isinstance(peer, types.PeerUser):
        return f"user:{peer.user_id}"
    if isinstance(peer, types.PeerChat):
        return f"chat:{peer.chat_id}"
    if isinstance(peer, types.PeerChannel):
        return f"channel:{peer.channel_id}"
    return None


def entity_key(entity):
    if isinstance(entity, types.User):
        return f"user:{entity.id}"
    if isinstance(entity, (types.Chat, types.ChatForbidden)):
        return f"chat:{entity.id}"
    if isinstance(entity, (types.Channel, types.ChannelForbidden)):
        return f"channel:{entity.id}"
    return None


def iso(moment):
    if moment is None:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def display_name(entity):
    if entity is None:
        return None
    if isinstance(entity, types.User):
        name = " ".join(part for part in (entity.first_name, entity.last_name) if part)
        return name or (entity.username and f"@{entity.username}") or None
    return getattr(entity, "title", None)


def chat_scope(entity, self_id, participants=None):
    """Returns (kind, synced, reason). `participants` overrides the entity's
    own participants_count, which Telegram often leaves out (the connector
    asks for the full channel when it needs to know)."""
    if isinstance(entity, types.User):
        if entity.id == self_id:
            return "saved", True, None
        if entity.bot:
            return "bot", False, "bot"
        return "direct", True, None
    if isinstance(entity, (types.Chat, types.ChatForbidden)):
        return "group", True, None
    if isinstance(entity, (types.Channel, types.ChannelForbidden)):
        if not getattr(entity, "megagroup", False):
            return "channel", False, "broadcast_channel"
        count = participants if participants is not None else getattr(entity, "participants_count", None)
        if count is None or count > SMALL_GROUP:
            return "supergroup", False, "large_group"
        return "supergroup", True, None
    return None, False, None


def chat_event(entity, self_id, last_activity=None, history_from=None, participants=None):
    kind, synced, reason = chat_scope(entity, self_id, participants)
    sync_state = {"synced": synced}
    if reason:
        sync_state["reason"] = reason
    if history_from:
        sync_state["history_from"] = iso(history_from)
    if getattr(entity, "forum", False) and synced:
        sync_state["topics"] = "unsupported"
    chat = {"provider_chat_id": entity_key(entity), "name": display_name(entity) or ("Saved Messages" if kind == "saved" else None),
            "kind": kind, "sync_state": sync_state}
    if last_activity:
        chat["last_activity_at"] = iso(last_activity)
    return {key: value for key, value in chat.items() if value is not None}


MEDIA_KINDS = (
    (types.MessageMediaPhoto, "photo"),
    (types.MessageMediaGeo, "location"),
    (types.MessageMediaGeoLive, "location"),
    (types.MessageMediaVenue, "location"),
    (types.MessageMediaContact, "contact"),
    (types.MessageMediaPoll, "poll"),
    (types.MessageMediaDice, "dice"),
)


def media_kind(media):
    if media is None or isinstance(media, (types.MessageMediaEmpty, types.MessageMediaWebPage)):
        return None
    for media_type, kind in MEDIA_KINDS:
        if isinstance(media, media_type):
            return kind
    if isinstance(media, types.MessageMediaDocument):
        attributes = getattr(media.document, "attributes", None) or []
        for attribute in attributes:
            if isinstance(attribute, types.DocumentAttributeAudio):
                return "voice" if attribute.voice else "audio"
            if isinstance(attribute, types.DocumentAttributeVideo):
                return "video_note" if attribute.round_message else "video"
            if isinstance(attribute, types.DocumentAttributeSticker):
                return "sticker"
            if isinstance(attribute, types.DocumentAttributeAnimated):
                return "gif"
        return "document"
    return "other"


def message_event(message, entities):
    """A types.Message → a message.upsert item, or None for service messages.
    `entities` maps typed peer keys to User/Chat/Channel objects."""
    if not isinstance(message, types.Message):
        return None
    chat = peer_key(message.peer_id)
    sender = peer_key(message.from_id) if message.from_id else chat
    if message.out:
        sender = entities.get("self") and f"user:{entities['self'].id}" or sender
    kind = media_kind(message.media)
    item = {
        "provider_message_id": str(message.id),
        "chat": chat,
        "sender_id": sender,
        "sender_name": display_name(entities.get(sender)) if not message.out else display_name(entities.get("self")),
        "sent_at": iso(message.date),
        "media_kind": kind,
        "edited_at": iso(message.edit_date),
    }
    if kind:
        item["caption"] = message.message or None
    else:
        item["body"] = message.message or ""
    return {key: value for key, value in item.items() if value is not None}


def edit_event(message):
    if not isinstance(message, types.Message) or message.edit_date is None:
        return None
    item = {"provider_message_id": str(message.id), "chat": peer_key(message.peer_id), "edited_at": iso(message.edit_date)}
    if media_kind(message.media):
        item["caption"] = message.message or None
    else:
        item["body"] = message.message or ""
    return item
