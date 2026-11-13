# Postiz: drafts, publishing, schedules and media

In **Integrations → Postiz**, paste a personal API token from Postiz settings.
Leave the API base blank for `https://api.postiz.com/public/v1`, or supply a
public HTTPS self-hosted base such as
`https://social.mexzungu.com/api/public/v1`. Private destinations and redirects
are refused. Every request resolves and validates all addresses and pins the
connection to the checked address, retaining TLS hostname verification.

This is a personal connection. Enable it for a resident using the normal service
grant controls; guest use still needs home approval. Revocation or a disabled
grant prevents subsequent calls. The token is encrypted in Rails and never
included in resident credentials or browser connection props.

## Authority and rollout

Connections default to drafts and uploads only. To allow publishing and
scheduling, reconnect with the **Allow publishing** field set to `enabled`.
Blank or `disabled` does not enable publication. Existing connections retain
their draft-only authority; deployment does not silently upgrade them.
The runtime's `publishing_enabled` boolean reports this gate.

This is house-enforced authority, not a Postiz token scope. Brand review,
legal review and the owner's publishing instructions still apply: this
connector does not certify approval. Draft is an explicit nonpublishing mode.
Uploading a file also does not publish it. There is no delete operation.

## Resident endpoints

Authenticate all house endpoints with
`Authorization: Bearer $SOULSHOUSE_BEARER_TOKEN`, never a Postiz token:

* GET `credentials.channels_endpoint`: sanitized channel listing.
* POST `credentials.drafts_endpoint`: legacy text-only `{channel_id,content}`.
* POST `credentials.posts_endpoint`: the new explicit post contract below.
* POST `credentials.uploads_endpoint`: multipart form with one field, `file`.

```json
{
  "channel_id": "channel-id",
  "content": "Reviewed text",
  "mode": "scheduled",
  "scheduled_at": "2027-01-15T10:00:00+01:00",
  "settings": {},
  "media": []
}
```

`mode` is required: `draft`, `publish_now`, or `scheduled`. Only scheduled
mode accepts `scheduled_at`; it must be a future ISO8601 instant with `Z` or
a numeric offset. The house normalizes it to UTC before sending it to Postiz.
An offset identifies an instant; the connector does not interpret local
wall-clock time or resolve daylight-saving ambiguities for the caller.
Postiz receives `draft`, `now`, or `schedule`, respectively.

Unknown top-level and provider settings are rejected. The house builds the
payload; callers cannot supply raw Postiz `posts`, `type`, `date`, integration,
republish or discriminator fields. Disabled channels are rejected.

## Media

Upload a local file using multipart, for example:

```sh
curl --fail-with-body \
  -H "Authorization: Bearer $SOULSHOUSE_BEARER_TOKEN" \
  -F 'file=@/path/to/photo.jpg;type=image/jpeg' \
  "$UPLOADS_ENDPOINT"
```

JPEG, PNG and WebP are limited to 10 MiB; MP4 to 50 MiB. The house checks the
declared type, file signature and size, generates the outbound filename and
streams a bounded multipart body. These checks are not full codec, duration,
aspect-ratio or platform-policy validation; the destination may still reject
media. Image/video limits are deliberately narrower than Postiz's maximums.

The response is `{id,path,upload_token}`. Pass the **complete receipt** as an
entry in `media`. The signed token binds its ID and URL to this connection;
modified receipts, receipts from another connection and arbitrary URLs fail.
Only `{id,path}` goes to Postiz. Tokens have no expiry so saved drafts can be
used later; they grant no access without an effective connection grant.
Do not log bearer credentials or upload tokens.

URL-upload is deliberately absent: Postiz would fetch the URL on its own
network, where the house cannot pin DNS or control redirects. Upload responses
must contain public HTTPS media URLs; private or insecure self-hosted storage
is not supported. Channel responses are allowlisted, never raw integration
objects (GHSA-jhfm-m4vp-jcpc).

## Platform settings

The existing text platforms remain supported: X, LinkedIn profiles/pages,
Threads, Mastodon, Bluesky, Telegram, Nostr and VK. X defaults to
`who_can_reply_post: "everyone"`; its other accepted values are
`mentionedUsers` and `following`. Other text platforms accept empty settings.

Additional providers accept this deliberately bounded subset:

| Provider identifier | Settings |
| --- | --- |
| `facebook` | Optional `post_type` (`post`/`story`), `title`, `text_format_preset_id` |
| `instagram`, `instagram-standalone` | Required `post_type` (`post`/`story`); optional boolean `is_trial_reel`, `graduation_strategy` (`MANUAL`/`SS_PERFORMANCE`) |
| `tiktok`, `tiktok-business` | Required `privacy_level`, booleans `duet`, `stitch`, `comment`, `brand_content_toggle`, `brand_organic_toggle`; `autoAddMusic` (`yes`/`no`); `content_posting_method` (`DIRECT_POST`/`UPLOAD`). Optional `title` (90 characters), boolean `video_made_with_ai` |
| `youtube` | Required nonempty `title` (100 characters), `type` (`public`/`private`/`unlisted`); optional `selfDeclaredMadeForKids` (`yes`/`no`) |

TikTok privacy values: `PUBLIC_TO_EVERYONE`, `MUTUAL_FOLLOW_FRIENDS`,
`FOLLOWER_OF_CREATOR`, `SELF_ONLY`. Its `UPLOAD` means TikTok-app inbox, **not**
publication; publication modes require `DIRECT_POST`. Optional music,
collaborators, locations, thumbnails and other nested settings are not
supported in this first extension. Do not infer support for all features of
a provider from its presence here.

Instagram, TikTok and YouTube require media even for drafts. Media count and
type checks are enforced before a post write. The legacy `draft_supported`
field describes the legacy text endpoint, not the richer media endpoint.
Facebook text drafts also work through that legacy endpoint. `post_supported`
describes the richer endpoint; `media_required` identifies providers that
cannot accept text alone. These capabilities do not override connection
publication authority or a channel's disabled status.

## Contract evidence and acceptance

Source-verified against upstream `gitroomhq/postiz-app` commit
`7fa06d1200c9d9f54754dad04139a18d70906c04`:

* `apps/backend/src/public-api/routes/v1/public.integrations.controller.ts`
  (`/posts`, multipart `/upload`, response handling).
* `libraries/nestjs-libraries/src/dtos/posts/create.post.dto.ts` and
  `providers-settings/all.providers.settings.ts`,
  `providers-settings/{x,linkedin,facebook,instagram,tiktok}.dto.ts` and
  `providers-settings/youtube.settings.dto.ts`.
* `libraries/nestjs-libraries/src/dtos/media/media.dto.ts`,
  `upload/{local.storage,cloudflare.storage,custom.upload.validation}.ts`.

This is source-contract verification, **not** a live test of the owner's
installed version. No publishing is performed during development. After
deployment: verify uploads and drafts on all relevant channels, then one
brand-cleared scheduled post on the owner's chosen channel, checked on the
destination platform. Owner publication opt-in is required first.

No writes are automatically retried. A timeout, HTTP error or broken receipt
can leave the outcome unknown: inspect Postiz before retrying. A successful
create receipt is not proof of eventual publication. Disconnecting removes
the house's token; revoke it in Postiz too when retiring it.
