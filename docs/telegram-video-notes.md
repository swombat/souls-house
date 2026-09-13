# Telegram round video notes

Inbound Telegram `video_note` messages use the existing video preparation and
display path. Their `duration` is retained and their square `length` becomes
both `width` and `height` in media metadata. Like ordinary videos, notes begin
with `[Video — processing]`, are deduplicated by Telegram message ID, and
are subject to the existing 20 MB video limit and content-type validation.

No new media kind or database migration is needed. This change does not add
support for other Telegram message types or change unsupported-message logging.

After deployment, send a round video note to a subscribed bot and confirm it
appears as a pending video, becomes ready, and reaches the resident with a
playable attachment. This live check verifies Telegram download/content-type
handling as well as ingestion; mocked job tests alone do not establish that.
