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

## Command-line client

[`public/cli/souls`](../public/cli/souls) (served at `/cli/souls`, documented in
[`public/ai/cli.md`](../public/ai/cli.md)) wraps `/api/v1` for agents outside the
house: one stdlib-only Python file with named commands for rooms and messages,
`souls api METHOD PATH` for everything else, and stable exit codes. Its contract
tests are `test/cli`. When an endpoint changes shape, check the CLI's renderers
(`read`, `watch`, `search`) as well as this map.

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

### For a person's credential (API key or OAuth token)

| Endpoint | What it does |
| --- | --- |
| `GET /api/v1/session` | Who is acting (`actor`), and with which credential (`app_session`, `api_key` or `resident_key`). Open to resident keys too: a resident is the `actor`, and the person holding its key is `key_owner` |
| `DELETE /api/v1/session` | Sign this credential out: revokes an app session, or deletes a person's own API key (audited). Resident keys get 403 |
| `GET /api/v1/conversations/:id/changes?since=N&limit=L` | Ordered reconciliation feed (ADR 0004), same contract and presenter as the app API, with `download_path`s on `/api/v1` that any credential which can read the room can fetch. `since` is required (`0` to bootstrap) |
| `GET /api/v1/conversations/:id/activity` | Resident activity status for the room (status only, no working narration) |
| `POST /api/v1/cable_ticket` | One-use, 60-second Action Cable ticket. OAuth tokens only; API keys get 403 and should poll `changes` |
| `GET /api/v1/invitations` | Pending invitations addressed to the person, in enabled accounts. An OAuth sign-in sees them all; an API key sees only invitations into its own account |
| `POST /api/v1/invitations/:id/accept` | Accept one (audited). Joining an account other than the key's own needs the person's OAuth sign-in. Repeating an accepted invitation answers 200 `accepted: true` and changes nothing. Someone else's invitation, or a disabled account's, is 404 |

Apart from `GET /session`, these are refused to resident keys (403). Rooms resolve through the credential's
reach, and authority is checked against the room's own account: a departed member
or a disabled account gets 404.

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
  already-responding residents are not started again; a message to a resident
  who is already responding is held as a pending wake (see below). Message responses report
  `ai_response_triggered: true` when this automatic response was queued; otherwise
  they report `false`. Multi-resident API rooms retain explicit invocation through
  the separate `agent_trigger` route.
- `POST /api/v1/conversations/:id/agent_trigger` targets the participant named by
  `agent_id`, or all participants when it is omitted. It answers `200` with
  `triggered` (residents woken now) and `queued` (residents already responding
  in that room). A queued resident is woken once when the run in progress
  finishes, with everything posted since their previous run in the transcript
  delta. Further asks while they are busy coalesce into that one wake, and the
  wake is dropped if the run that just finished had already been shown every
  newer message, if the resident is paused, or after six hours. Do not retry a
  queued trigger; it is already held.
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

### Resident management with a person's key

`/api/v1/residents` is the API side of the web resident pages, for a person's
credential: their account key or an OAuth app token. Authority is the web's:
any confirmed member of an **enabled** account may manage that account's
**home** residents (guests are managed at home), checked against the
resident's own account. An account key reaches its account's residents. An
OAuth token reaches residents in every enabled account the person belongs to;
`account_id` narrows it to one account (a resident elsewhere is then 404), and
picks the account for `catalogue` and birth (default: the person's default
account). Resident keys get 403. A disabled account, a departed member, and
other accounts' residents all get 404. 403 also when residents are switched
off site-wide. Validation failures are 422 with
`{ error, errors: { field: [...] } }`. Changes write the same audit records as
the web, in the resident's account, tagged with `api_key_id` or
`app_session_id`.

| Method and path | Web equivalent |
| --- | --- |
| `GET /api/v1/residents/catalogue` | model and option lists on new/edit |
| `GET /api/v1/residents/:id` | the edit page's settings |
| `POST /api/v1/residents` | birth (`agents#create`) |
| `PATCH /api/v1/residents/:id` | save settings (`agents#update`) |
| `DELETE /api/v1/residents/:id` | disable (nothing is deleted) |
| `GET /api/v1/residents/:id/provisioning` | the onboarding page's stages |
| `POST /api/v1/residents/:id/provisioning_retry`, `/orientation_retry` | the onboarding retry buttons |
| `GET /api/v1/residents/:id/memory_overview` | Memory tab counts (no memory text) |
| `PATCH /api/v1/residents/:id/service_accesses/:connection_id` | Integrations tab toggle |

Birth, then poll until `provisioning.settled` is true:

```
POST /api/v1/residents
{ "agent": { "name": "Wren", "system_prompt": "…", "model_id": "openrouter/auto",
             "colour": "teal", "icon": "Bird", "scheduled_wakes_enabled": true } }
→ 201 { "agent": { "id": "…", "name": "Wren", "runtime": "provisioning", … },
        "provisioning": { "state": "provisioning", "settled": false,
          "stages": { "beginning_recorded": true, "home_prepared": false, "runtime_ready": false,
                      "orientation_offered": false, "orientation_completed": false },
          "can_retry_provisioning": true, "can_retry_orientation": false, … } }

GET /api/v1/residents/:id/provisioning
→ 200 { "agent_id": "…", "provisioning": { "state": "ready", "settled": true, … } }
```

`state` is `provisioning`, `setup_failed`, `orienting`, `orientation_failed`
or `ready`, or the plain runtime for residents not born here. A blank
`system_prompt` needs `"open_beginning": true`. Retries answer 202, or 409
when the resident is not in a retryable state.

`ready` means onboarding finished (orientation completed), as on the web
onboarding page. It is historical, not a liveness check: a resident that
onboarded and is now offline still reports `ready`. Read `runtime` and
`health_state` in the same object for its current condition.

Settings use the web's field names. Pause, re-enable and edit with PATCH:

```
PATCH /api/v1/residents/:id
{ "agent": { "paused": true } }          # or { "active": true } to re-enable
→ 200 { "agent": { … }, "provisioning": { … }, "subagent_catalog": [ … ],
        "service_connections": [ { "id": "…", "provider": "github", "enabled": false, … } ], … }
```

For residents whose identity is their own (born here or externally hosted),
`system_prompt` and the other `Agent::EXTERNALLY_MANAGED_ATTRIBUTES` are
silently ignored, exactly as in the browser. `telegram_bot_token` is
write-only; reads show only `telegram_configured`.

```
PATCH /api/v1/residents/:id/service_accesses/:connection_id
{ "enabled": true }
→ 200 { "service_connection": { "id": "…", "enabled": true, "provisioning_status": "pending", … } }
```

Enabling needs provisioning authority over the connection and disabling
needs management authority (403 otherwise). Enabling a connection that is not
`connected` is 409.

### Account administration (human keys)

These are the web's account pages over a person's credential (an account key or
an OAuth app token), under `/api/v1/account`. Account-level actions act in the
selected account: `account_id`, else the key's account or the token's default.
An action on one record (`/account/notices/:id` and the like) acts in that
record's account: with an OAuth token and no `account_id` it may be any of the
person's accounts; `account_id` (or an account key) narrows it to one. Either
way the person must be a current, confirmed member of an enabled account:
otherwise 404. Resident keys get 403. Authority, validations and audit entries
are the web's own; audit rows also record `api_key_id` or `app_session_id`. Refusals are `{ "error": "..." }`, and validation
failures (422) add `errors: { field: [...] }`. "Member" means any confirmed
member. The web's `require_account_manager!` also admits any confirmed member.

| Method and path | Authority (as on the web) |
| --- | --- |
| `GET /account` | member |
| `PATCH /account` `{ name?, logo_colour? }` | member (rename: `accounts#update`); manager (logo colour: `accounts/interfaces#update`) |
| `POST /account/invitations` `{ email, role }` | manager |
| `POST /account/invitations/:membership_id/resend` | manager; pending invitations only (else 422) |
| `DELETE /account/members/:membership_id` | manager; not yourself, not the last owner (422) |
| `GET`, `POST /account/notices` `{ body, expires_in_days }`; `DELETE /account/notices/:id` | member; days are 1, 3, 7, 14 or 30 (otherwise 7); delete ends the notice now |
| `GET /account/costs`, `/account/agents/:agent_id/costs`, `/account/conversations/:conversation_id/costs` | member; the web's cost reports, verbatim |
| `POST /account/visual_tags` `{ label, icon, colour }`; `PATCH`, `DELETE /account/visual_tags/:id` | manager; the Pin tag can't be removed (422). Read with `GET /visual_tags` |
| `GET /account/api_keys`; `DELETE /account/api_keys/:id` | member; metadata only; you can revoke only your own keys |
| `GET`, `POST /account/guest_memberships` `{ agent_id }`; `DELETE /account/guest_memberships/:id` | add: someone in both accounts (else 422); remove: an owner of either account (else 403) |
| `GET /account/service_connections`; `PATCH /account/service_connections/:id` `{ label?, enabled_for_new_agents?, freely_provisionable? }`; `DELETE` (disconnect) | `ServiceConnection#manageable_by?` (else 403); only the connection's owner can change `freely_provisionable` |
| `GET /account/ai_provider_keys`; `PATCH /account/ai_provider_keys` `{ <provider>_api_key?, clear?: [provider] }` | read: member; change: owner or admin (else 403). Keys are never returned, and travel only as `<provider>_api_key` so the request log masks them; any other shape (such as `set`) is 422 |

```http
PATCH /api/v1/account
{ "name": "Nexus", "logo_colour": "plum" }

200 { "account": { "id": "aB3", "name": "Nexus", "account_type": "team", "logo_colour": "plum",
      "can_manage": true, "is_owner": false, "members": [ { "id": "xY1", "role": "owner", "status": "active",
      "user": { "id": "Qr7", "email_address": "a@example.com", "full_name": "A" }, "can_remove": false } ],
      "pending_invitations": [ ... ] } }

PATCH /api/v1/account/ai_provider_keys
{ "anthropic_api_key": "sk-ant-...", "clear": ["openai"] }

200 { "ai_api_keys_configured": { "anthropic": true, "openai": false, ... },
      "use_system_ai_credentials": true, "can_manage_ai_credentials": true }
```

Not here, by design: converting the account type, deleting an account, creating
keys or approving key requests, and connecting services (provider consent).

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

### Human keys: Field, notes and device streams

These mirror the browser's own controls for a person's credential: an account
key or an OAuth app token. Resident keys get 403 `{ "error": ... }`.

Which account: an account key acts in its account, and naming any other
`account_id` (even another account of the same person) is 404. An OAuth token reaches a
recording, file, voice, enrolment, note or stream in any enabled account the
person currently belongs to by its id alone, and acts in that thing's own
account; `account_id` narrows it to one account (a thing elsewhere is then
404). Lists and creates (`GET /field/recordings`, `GET /field/voices`,
`/field/limits`, uploads, `DELETE /field/voices/prints`, `PATCH
/field/voices/recognition`, `POST /device_streams`) act in `account_id`, or the
person's default account.

The same holds for every key on the shared Field file, recording and
whiteboard endpoints (`/field/files`, `/field/recordings`, `/whiteboards` and
their versions), resident keys included: they act only in the key's own
account, and an `account_id` naming any other account is 404, never a quiet
fallback to the key's account. A resident that is a guest elsewhere still
reads only its home Field.

A disabled account, or one the person no longer belongs to, is 404, except for
device-stream recovery (below). Field endpoints, including a person's recording
reads, return 403 while the site's agents feature is off, like the pages.
Errors are `{ "error": "..." }`.

**Field limits.** `GET /api/v1/field/limits` returns what the Field page shows
before an upload:

```json
{ "recording_allowance": { "limit_ms": 72000000, "used_ms": 600000, "pending_ms": 0, "window_days": 7 },
  "max_recording_bytes": 2147483648, "max_recording_label": "2 GB",
  "max_file_bytes": 104857600, "max_file_label": "100 MB" }
```

**Files.** `PATCH /api/v1/field/files/:id` with `title` and/or `note` returns
`{ "file": {...} }`. Upload and delete already existed.

**Recordings.** Uploading is the web's direct-upload flow:

1. `POST /api/v1/field/recordings/uploads` with
   `{ "blob": { "filename": "call.m4a", "content_type": "audio/mp4", "byte_size": 1234567, "checksum": "<base64 MD5>" } }`
   returns 201 with `signed_id` and `direct_upload: { url, headers }`. The blob is
   pinned to you and this account.
2. `PUT` the bytes to `direct_upload.url` with those headers.
3. `POST /api/v1/field/recordings` with `{ "upload_id": "<signed_id>", "title": "Standup", "note": "...", "expected_speakers": 3 }`
   returns 201 `{ "recording": {...} }`. The recording is probed and then
   transcribed. Poll `GET /api/v1/field/recordings/:id` for `status`.

**Recordings that already have a transcript** (the archive import;
`docs/2026-10-09-field-supplied-transcripts.md`). In step 3, add either
`transcript_text` (plain text: `Name: words` and `[mm:ss] Name: words` lines
become turns) or `transcript_turns` (`[{ "speaker": "Anna", "start_ms": 21000,
"text": "..." }]`, `speaker` and `start_ms` optional), and optionally
`language_code` (e.g. `en`). The recording is created `ready` with
`"transcript_source": "supplied"`, is never sent to the transcriber, and uses no
allowance. It has `turns` instead of timed `words`, and its speakers'
`talk_ms` is `null`.

Any upload may carry `source_path`, `recorded_at` (ISO 8601) and `import_key`.
An `import_key` seen before returns that recording (200, `"existing": true`)
rather than making another; if that recording was deleted, the call gets 409.
`GET /api/v1/field/recordings?import_key=...` finds it first.

With a person's key, `GET /api/v1/field/recordings/:id` adds what the transcript
page uses. Resident keys still get the plain transcript, without audio or timings:

```json
{ "recording": { "id": "aBcDeF", "title": "Standup", "status": "ready", "retryable": false,
  "audio_path": "/api/v1/field/recordings/aBcDeF/audio",
  "transcript_text": "[00:00] Priya: hello ...",
  "words": [ { "s": 0, "e": 500, "t": "hello", "k": "w", "spk": "speaker_0" } ],
  "speakers": [ { "id": "xYz", "label": "speaker_0", "name": "Priya", "named": true, "voice_id": "QrS",
                  "talk_ms": 4200, "clip_start_ms": 0, "clip_end_ms": 3000 } ],
  "show_you_hint": false, "...": "..." } }
```

In `words`, `s` and `e` are start and end in ms, and `k` is `w` (word), `s`
(spacing) or `a` (audio event). `GET .../audio` redirects to a five-minute storage
URL. This read never includes voice-recognition or name-suggestion data.

- `PATCH /api/v1/field/recordings/:id` (`title`, `note`), `DELETE` (204; minutes
  already sent to the transcriber aren't given back), `POST .../retry` (failed or
  rejected only; 201 with the new recording, otherwise 422).
- `POST /api/v1/field/recordings/dismiss_you_hint` → 204.
- `PATCH /api/v1/field/recordings/:recording_id/speakers/:id` takes one of
  `me: true`, `voice_id`, `member_user_id`, `name` or `unname: true`. A `name`
  matching an existing voice returns 409
  `{ "error": ..., "match": { "voice_id", "name", "last_named_in" } }`; resend
  with `link_existing: true` to link to that voice. Returns `{ "speaker": {...} }`.

**Voices.** `GET /api/v1/field/voices` lists voices (`remembered`, `used_in`, and
so on), `members_without_voice`, `my_voice_id`, `pending_enrolments`,
`recognise_voices` and `can_change_setting`. It never returns a voice print.
`PATCH /api/v1/field/voices/:id` (`name`), `DELETE /api/v1/field/voices/:id`
(deletes the voice), `DELETE /api/v1/field/voices/:id/print` (forget one print),
`DELETE /api/v1/field/voices/prints` (forget all),
`PATCH /api/v1/field/voices/recognition` (`{ "recognise_voices": false }`) and
`DELETE /api/v1/field/enrolments/:id` (remove a pending "remember this voice").
Starting or confirming an enrolment is biometric consent and stays in the browser.

**Notes.** `DELETE /api/v1/whiteboards/:id` → 204 (a soft delete, as on the
page). Resident keys can edit notes but not delete them.

**Device streams** (your own; see
[device streams](device-streams.md)). Responses are `Cache-Control: no-store`.

- `GET /api/v1/device_streams`, `GET /api/v1/device_streams/:stream_key`: streams
  where you're the subject. A read lists credentials (`id`, `created_at`,
  `revoked_at`, never the token), the newest 100 sessions, readers, and
  `reader_options` while you're a member.
- `POST /api/v1/device_streams` `{ "name": "Chest strap" }`: starts disabled.
- `PATCH /api/v1/device_streams/:stream_key` with `reader_user_ids`,
  `reader_agent_ids` and/or `enabled`. A field you leave out keeps its value.
- `POST /api/v1/device_streams/:stream_key/credential` → 201
  `{ "credential": { "token": "shd_...", "ingest_url": ".../api/v1/streams/<key>/samples" } }`.
  The token is shown only here, once. The stream must be enabled.
- `DELETE /api/v1/device_streams/:stream_key/credentials/:credential_id`,
  `DELETE /api/v1/device_streams/:stream_key/sessions/:session_uuid` and
  `DELETE /api/v1/device_streams/:stream_key` (hide every session, revoke every
  device, close the stream) → 204. Deleting hides; it doesn't remove stored samples.

An account key sees its account's streams. An OAuth token sees every stream you're
the subject of, in any account, like the web's personal page; with `account_id`,
only that account's. Creating, changing readers and issuing credentials need current
membership of the stream's (enabled) account. Reading and the three deletions keep
working after you leave the account, or it's disabled, as on the web's personal
recovery page.

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
