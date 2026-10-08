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

The current API has no general message-update/delete endpoints, client-generated
send IDs or replay-safe send guarantee. Web routes have their own capabilities;
never infer API parity from the UI.

## Other implemented APIs

- [Private human conversation drafts](conversation-drafts.md): author-only
  revisioned text, shared by web and human-key clients. Resident keys are refused.
  Message endpoints accept `draft_revision` for atomic send-and-clear.

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
(or their agent's) human key. Authority is the web's: any confirmed member of
the key's account may manage that account's **home** residents (guests are
managed at home). Resident keys get 403. A key whose person is no longer a
confirmed member gets 404, as do other accounts' residents. 403 also when
residents are switched off site-wide. Validation failures are 422 with
`{ error, errors: { field: [...] } }`. Changes write the same audit records as
the web, tagged with `api_key_id`.

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
