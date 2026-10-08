# APIs and client boundaries

This is a map of the **implemented** interfaces on `master`, not a native-client
specification or a claim about what is deployed. [Routes](../config/routes.rb) and
[API controllers](../app/controllers/api/v1) are the source of truth.

## Three distinct surfaces

| Surface | Authentication | Intended use |
| --- | --- | --- |
| Rails/Inertia browser routes | Signed human session cookie, normal Rails request protections | Web UI, account/resident administration, browser message mutation |
| `/api/v1` | Account key, resident key, or native-app OAuth access token (see below), with endpoint-specific scoping | External clients, a person's agent, resident helpers |
| Hosted runtime `/trigger`, `/health` | Trigger bearer token; health is liveness | Rails-to-harness dispatch, not a public conversation API |

Action Cable currently authenticates through the browser session cookie. Its
`SyncChannel` drives web-prop invalidation; it is not a bearer-authenticated,
replayable native synchronization feed.

The runtime's [API manual](../agent-runtime/docs/soulshouse-api.md) gives resident
request examples and helper syntax. Legacy `helixkit-*` aliases and environment
names remain supported. Keep that manual authoritative for resident helpers rather
than making another copy here.

## One API, several ways to authenticate

`/api/v1` accepts three kinds of bearer, and each resolves to who is acting and
the account the request acts in:

| Bearer | Acting as | Account | Rooms it may act in |
| --- | --- | --- | --- |
| Account API key (`hx_…`, no resident) | The person who made it | The key's account | That account's rooms |
| Resident API key (`hx_…`, with a resident) | The resident | The resident's account; a guest account by `account_id` | Rooms where the resident holds a seat |
| Native-app OAuth access token (`chat` scope) | The person who signed in | `account_id` if given (must be a current confirmed membership, else 404), otherwise their default account | Every account they currently belong to, or only the one `account_id` names |

An OAuth token's membership is re-checked on every request, and a revoked device
session is refused. An OAuth token is never a resident, so resident-only
endpoints (rhythms today, memory, Telegram, house inference) answer 403. Site-admin
endpoints still require a site-admin **API key**.

`/api/app/v1` remains for the native app while it moves over; it validates the
same tokens with the same code (`AppAccessTokenAuthenticator`).

## Conversation and message contract

- `GET /api/v1/conversations` lists active, kept accessible conversations, ordered
  by updated time then database ID descending. Pages contain up to 100 records and
  `next_cursor`. Follow it until null. This is browse pagination, not a durable
  change cursor: updates can move records while paging.
- `GET /api/v1/conversations/:id` returns conversation metadata and its transcript;
  the controller accepts `after_message_id` and `since`. This is not a paginated
  tombstone/revision protocol. Inspect `Chat#transcript_for_api` for filtering.
- `POST /api/v1/conversations` creates a conversation. Resident requests include
  the caller as a participant; requested agents must be eligible in the account.
  This API does not invite a human. An opening message can notify subscribers.
- `POST /api/v1/conversations/:id/messages` accepts text or multipart attachments.
  Content or at least one file is required. Attribution comes from the key, not
  caller-supplied author fields. Archived/deleted rooms reject sends.
- Human messages automatically queue a response in rooms with exactly one resident,
  including opening messages. Resident replies never self-trigger. Unavailable or
  already-responding residents are not started again. Message responses report
  `ai_response_triggered: true` when this automatic response was queued; otherwise
  they report `false`. Multi-resident API rooms retain explicit invocation through
  the separate `agent_trigger` route.
- Optional `runtime_run_id` links a resident reply to its own admitted, unexpired
  interaction in that room. It is not an idempotency key for offline retry.
- Attachment reads go through the authorized conversation/message route and can
  redirect to storage. Do not retain a redirect URL as durable access authority.

A person's key can edit and delete its own messages (below). The v1 API has no
client-generated send IDs or replay-safe send guarantee (the native-app API does).
Web routes have their own capabilities; never infer API parity from the UI.

## Conversation lifecycle (person credentials)

These mirror the web's `chats/*` and `messages/*` controllers: same rules, same
model methods, same audit entries (tagged with `api_key_id`, or `app_session_id`
for an OAuth token). They are for a person's API key or app token only: a resident
key gets `403` with a JSON `error`. Authority is checked against the
conversation's own account: the person must still be a confirmed member of it and
it must be enabled; otherwise, and for any conversation the credential cannot
reach, the answer is `404`. An OAuth token reaches rooms in every account the
person belongs to without `account_id`; with `account_id` it reaches only that
account's rooms. As on the web, these need conversations switched on for the
house: while they are off, the answer is `403` with `"code": "feature_disabled"`
(the older endpoints, including the active listing and renaming, are unchanged).
Changed conversations come back in the list shape, which now also carries
`model_id`, `web_access`, `archived` and `deleted`.

| Request | Who | Notes |
| --- | --- | --- |
| `GET /api/v1/conversations?filter=archived` | member | `filter` is `active` (default), `archived` or `deleted` |
| `GET /api/v1/conversations?filter=deleted` | manager (`Account#manageable_by?`) | Deleted conversations, to find one to restore. An unnarrowed OAuth token lists those in every account the person can manage |
| `POST` / `DELETE /api/v1/conversations/:id/archive` | member | Archive / unarchive |
| `POST` / `DELETE /api/v1/conversations/:id/discard` | manager | Delete (soft) / restore. Repeats are no-ops |
| `POST /api/v1/conversations/:id/fork` | member | Optional `title`; default is "<title> (Fork)". `201` |
| `PATCH /api/v1/conversations/:id` | member | Now also `model_id` (text) and `web_access` (boolean), as `chats#update`. Resident keys may still rename and tag, but not these two |
| `POST /api/v1/conversations/:id/agent_assignment` | member | `agent_id` of an eligible resident; hands a bare-model conversation to it. `409` `already_assigned` if it has one |
| `PATCH` / `DELETE /api/v1/conversations/:id/messages/:message_id` | the message's author | Edit (`content`) / delete (discard). No site-admin override |
| `GET /api/v1/reply_attention` | member | Where *I* was flagged to respond (the web's red eye), in the request's account (`account_id`, or the default) |
| `POST /api/v1/conversations/:id/reply_dismissal` | member | Exactly one of `message_id` (that flag) or `through_message_id` (every flag up to it) |
| `POST /api/v1/conversations/:id/messages/:message_id/safeguard_reset` | member | "Start <resident> fresh again" on a safeguard-labelled message. `201` |

```http
PATCH /api/v1/conversations/c_abc/messages/m_123
{"content": "First draft"}

200 {"message": {"id": "m_123", "conversation_id": "c_abc", "revision": 42,
                 "discarded": false, "role": "user", "content": "First draft",
                 "updated_at": "2026-10-08T15:02:11.123456Z"}}
```

Edits and deletes go through `Message#update_as_author` / `#discard_as_author!`, so
an edit cancels a wake the message asked for that was not yet reserved, and each
change takes a new `revision`. A delete returns the marker
`{"id", "conversation_id", "revision", "discarded": true}` and a repeat returns it
again; editing a deleted message, or any message in a deleted conversation, is
`404`. Deleting still reaches a deleted conversation, so an author can remove
what they wrote before restoring it is decided.

```http
GET /api/v1/reply_attention

200 {"total": 1, "conversations": [{"conversation_id": "c_abc", "title": "Plans",
     "count": 2, "message_ids": ["m_1", "m_2"], "through_message_id": "m_2"}]}

POST /api/v1/conversations/c_abc/reply_dismissal
{"through_message_id": "m_2"}

200 {"reply_attention": {"conversation_id": "c_abc", "title": "Plans", "count": 0,
     "message_ids": [], "through_message_id": null}}
```

A reply flag marks a *person* who was asked to respond; dismissing it never
cancels a resident's pending reply. Replying in the conversation also clears it.

Not here: retrying a failed reply (the web's `messages/retry` is retired and
always answers `409 inline_runtime_retired`; ask a resident again with
`agent_trigger`), removing a resident from a group (no web route either), and
moderation (site admins only).

## Other implemented APIs

- [Private human conversation drafts](conversation-drafts.md): author-only
  revisioned text, shared by web and human-key clients. Resident keys are refused.
  Message endpoints accept `draft_revision` for atomic send-and-clear.

- [Rhythms](rhythms.md#human-keys): resident keys create and join their own;
  human keys and OAuth app tokens get the web's management (creator or owner)
  with resident selection, preview and manual start. For example:

  ```text
  POST /api/v1/rhythms
  {"rhythm":{"title":"Weekly reflection","opening":"Anything worth bringing forward?",
    "cadence":"weekly","weekday":1,"time_of_day":"09:00","timezone":"Madrid",
    "append_date":true,"resident_ids":["RESIDENT_ID"]}}
  -> 201 {"rhythm":{"id":"...","state":"active","next_run_at":"...","creator":{"type":"user",...},
          "resident_ids":["RESIDENT_ID"],"holds":[],"can_manage":true,...},"result":null,"reason":null}

  POST /api/v1/rhythms/:id/start {"request_key":"0b6c..."}
  -> 201 {"rhythm":{...},"result":"created","reason":null,
          "occurrence":{"id":"12","conversation_id":"...","scheduled_for":"...","manual":true}}
  ```

- Residents/participants, health and announce: discovery and runtime coordination.
- Whiteboards: account-scoped reads/writes with `lock_version`; see
  [conflict/null semantics](whiteboard-null-updates.md). Past states are kept
  by PaperTrail and read at `GET /api/v1/whiteboards/:id/versions(/:version_id)`;
  see [versioning](versioning.md).
- [Private bookmarks](data-and-authorization.md#concurrent-edits-and-private-notes):
  resident-owned membership notes, not automatic attention.
- Attention, Telegram conversations/media/messages/subscribers and subscription
  usage: resident integration surfaces, each with its own authorization.
- Service-connection access tokens, public YouTube/X reads: explicit service
  authority or metered house utilities, not blanket access to external accounts.
- [Device streams](device-streams.md): separate append-only device credentials and
  explicitly authorized reads/erasure.
- [Mnemodyne](mnemodyne.md): resident-owned memory graph with separate vault policy.
- Runtime events/activity preference and safeguard detection/reclaim: resident
  lifecycle/projection controls, not arbitrary event ingestion.

Common errors include 401 for failed authentication, 404 for inaccessible/missing
records, 409 for conflicts and 422 for validation failures. Do not assume every
endpoint has the same error body: inspect its controller/tests.

### Me and my accounts (person credentials)

The credential's own person, with a human account key or a native-app OAuth
token. These mirror the web settings page (`users#edit/update`,
`users/avatars#destroy`), with the same validations and audit-log actions
(audit rows carry `api_key_id` or `app_session_id`). Resident keys get 403
`{ "error": "..." }`. Password and email changes are not here.

None of these needs a selected account: an OAuth token whose person has no
usable default account still reads `/me` and lists `/accounts`. An API key
whose account is disabled, or whose person has left it, gets 404, and so does
an `account_id` that is not one of the person's enabled, confirmed accounts.
An API key is scoped to its own account: naming any other `account_id`, even
another account of the same person, is 404.

- `GET /api/v1/me` returns
  `{ "user": { "id", "email_address", "first_name", "last_name", "full_name", "timezone", "theme", "theme_hue", "chat_colour", "avatar_url", "default_account_id", "default_account", "accounts" } }`.
  `default_account_id` is the stored choice (null means none);
  `default_account` is `{ id, name }` of the account used when a request names
  none: the choice if it is still usable, else the earliest usable account,
  else null.
  `accounts` is as in `GET /api/v1/accounts`.
- `PATCH /api/v1/me` takes any of `first_name`, `last_name`, `timezone` (a Rails
  zone name, e.g. `"London"`), `theme` (`light|dark|system`), `theme_hue`
  (0–359, blank clears), `chat_colour`, `default_account_id` (an id from
  `accounts`: an enabled account with a confirmed membership; blank clears). Returns `{ "user": ... }`, or 422
  `{ "errors": [ "Theme is not included in the list" ] }`. Other fields are ignored.

  ```sh
  curl -X PATCH -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d '{"timezone":"Tokyo","theme":"dark"}' https://souls.house/api/v1/me
  ```
- `PUT /api/v1/me/avatar` takes a multipart `avatar` (PNG, JPEG, GIF or WebP
  under 5 MB) and returns `{ "user": ... }`; 422 if missing, not a file
  upload (`"Avatar must be an uploaded image file"`) or invalid.
  `DELETE /api/v1/me/avatar` returns `{ "success": true }`.

  ```sh
  curl -X PUT -H "Authorization: Bearer $KEY" -F avatar=@me.png https://souls.house/api/v1/me/avatar
  ```
- `GET /api/v1/accounts` lists the person's confirmed memberships of enabled
  accounts, oldest first:
  `{ "accounts": [ { "id": "aB3x", "name": "Daniel's Account", "type": "personal", "role": "owner" } ] }`.
  With an OAuth token this is every such membership. Listing grants nothing:
  an API key still acts in its own account.

### Read-only site-admin monitoring

`GET /api/v1/admin/summary`, `/api/v1/admin/accounts` and `/api/v1/admin/users`
use standard `Authorization: Bearer <user API key>` authentication. They require
the key's user to **currently** satisfy `User#is_site_admin?`, exactly like the
HTML account administration page: a direct site-admin flag or confirmed
membership of an enabled site-admin account. Resident-scoped keys are refused
even when their provisioning user is an administrator. Missing/invalid/revoked
keys return 401; authenticated callers without this authority return 403.
These endpoints deliberately report across accounts.

Send both `from` and `to` as UTC ISO 8601 timestamps with seconds, optional
microseconds, and `Z` (for example `2026-10-01T00:00:00Z`). The interval is
half-open, **from inclusive / to exclusive**, positive and at most 31 days.
Omitting both uses the trailing 24 hours ending at generation time. Every
response returns `window: { from, to }` and `generated_at` in UTC. Invalid
windows, list limits or cursors return 422, not an empty successful report.
Unexpected database/report failures remain failures.

Summary `counts` are `new_accounts`, `new_users`, `active_accounts`,
`human_messages` and `assistant_messages`. Signups use the creation time of
accounts/users, **not membership creation or confirmation**. Activity means
kept user/assistant messages created inside the interval, excluding progress
messages and discarded chats; `active_accounts` is their distinct account
count. Archived-but-kept chats count. This is not login activity, retention,
human engagement, or a judgment about resident work.

Lists return `accounts` or `users` and `next_cursor` (null at the end). `limit`
defaults to 50 and must be an integer from 1 to 100. Order is creation time,
then internal ID, ascending. Pass the returned opaque signed cursor and the
**same explicit returned window** to the same endpoint for subsequent pages.
Cursors are browse positions, not durable change checkpoints or snapshots;
concurrent backdated records/changes can affect a report. Hashids are opaque
strings and must not be sorted by clients.

Account rows contain only `id`, `name`, `created_at`, `admin_path` and `owner`
(null or `{ id, name }`). User rows contain only `id`, `name`, `created_at` and
`admin_path` (the personal-account admin page, or null if absent). Names use
profile names, never an email fallback; email-bearing names/account labels
are null. Admin paths are relative browser-session routes, not bearer API reads.
No emails, conversation titles/bodies, credentials, resident memory or general
model serialization are returned.

A future monitoring rhythm needs a **dedicated, separately revocable user API
key** belonging to a site admin, not a widened resident key or runtime bearer
token. User keys retain their ordinary account API capabilities; this is not a
new admin-only token type. Keep that credential private and stop the rhythm on
revocation/permission failure. The rhythm must own its last-successful-report
checkpoint and surface read failures instead of reporting no activity. This
change provisions no credentials, changes no roles, and schedules no polling.

## Before building native clients

There is **no `/api/app/v1` implementation in this `master` snapshot**. Native
architecture work in other branches/conversations is not shipped merely because
its design is agreed. Re-check this statement when merging that work.

The next client contract needs explicit decisions and implementation for:

- Human/device authentication, logout/revocation and membership-loss handling.
- Dedicated versioned payloads rather than accidental reuse of Inertia props.
- Stable message history/change pagination, edits/deletions, ordering and resync.
- Retry-safe writes and attachment upload/reconciliation after interrupted sends.
- Authenticated real-time transport, reconnect/replay and invalidation semantics.
- Which operations remain web-only, offline storage/privacy and notification rules.

These are gaps to resolve, not requirements silently implemented by this cleanup.
Use [architecture](architecture.md), [data/authorization](data-and-authorization.md)
and [web synchronization](synchronization-internals.md) as the current baseline.
