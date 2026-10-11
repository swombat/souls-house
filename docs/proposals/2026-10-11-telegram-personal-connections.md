# Personal Telegram connections, and a comms connector built for many users

Status: design for review (Lume, 2026-10-11). Brief: Mira in wJVAWj, from
Daniel's request in OjyBlJ. Daniel's requirement (wJVAWj, eGNQrj): design for a
multi-tenant site from the start. It must reach about 1,000 connected users
without re-architecting. Hyperscale is out of scope.

This document covers the Telegram user-account connection. Because Telegram's
would be the house's first real connector, it also covers the connector
architecture that WhatsApp (proposal 2026-10-09, PR #264) should share. Where
this document and the WhatsApp proposal's §2 differ ("one worker per
connection, held by a flock on /data/<ref>/lease"), this one is meant to
replace that section for both providers once reviewed.

## 0. What a user gets

A person connects their own Telegram account (a user account, not a bot) from
their integrations page, then grants it to residents the way any service is
granted. A granted resident can list chats, read the synced chats, and run a
bounded search through `soulshouse-comms`. Sending is possible only with a
separate send grant, and comes from the shared send machinery in #264.
Existing Telegram bots and house notifications are untouched.

## 1. Sizing target

Design point: 1,000 connected Telegram accounts, which means ~1,000
sessions. Anything that only works for one user, or only on one host, is out.

Rough load, to be measured rather than trusted:

- Synced scope per user (see §6) is DMs, Saved Messages and small groups.
  Assuming an average of 100–500 messages a day per user, that is
  100k–500k `comms_messages` rows a day at 1,000 users, or 35M–180M a year.
  Postgres handles this with the existing `(comms_chat_id, sent_at, id)`
  index. A retention policy, or partitioning by month, is an open decision
  (§11) before we pass a few hundred users, not a blocker for v1.
- Event ingestion is signed batches of up to 200 (`CommsEvents::MAX_BATCH`),
  so 500k messages a day is a few thousand requests a day. That's negligible.
- Telegram-side cost is one MTProto connection per *live* session (§4), not
  per connected user.

## 2. Connector shape: a pool of workers, each holding many sessions

`souls-house-comms` stays a private-network Kamal accessory, but it is a
**pool**: N identical worker processes, on one host or several. One codebase
per provider: Python/Telethon for Telegram, Go/whatsmeow for WhatsApp. They
share one protocol to Rails and one store design.

- A worker is an asyncio process (or goroutines for whatsmeow) holding many
  sessions concurrently. A session is a socket plus its update state, not a
  process. Target is a few hundred sessions per worker; the real figure
  (memory and file descriptors per idle Telethon client) gets measured in S2
  against Telegram's test DCs, and the pool is sized from that.
- Scaling is adding workers. Nothing in the design pins a connection to a
  host, a volume or a process.

### 2.1 The invariant: one live client per session, enforced by leases

A Telegram auth key (and a whatsmeow device) must never be live in two places
at once. That is the real constraint behind "one worker per connection".

- The connector's store (§3) has `session_leases(connection_ref, worker_id,
  fence, expires_at)`. A worker claims a lease with a conditional update that
  increments `fence`, and renews it every ~10 s with a ~30 s expiry.
- Every write a session makes to the store, and every outbound Telegram call
  that changes state (send, login steps), is guarded by "my fence is still the
  current fence". A worker that was paused (GC, VM stall) and comes back
  after its lease moved finds its fence stale and drops the session without
  touching anything.
- On a clean shutdown, a worker disconnects and then releases its leases. After
  a crash, leases expire and other workers claim them. Rebalancing is "release
  some, let others claim".
- Assignment is claim-on-demand: workers claim connections that need to be
  live (§4), up to their capacity. No coordinator process.

## 3. The connector store

One Postgres database for the connector (`comms_connector`), with its own role
on the house Postgres server. Rails' role cannot read it, and the connector's
role cannot read Rails'. Not files on a volume: any worker must be able to pick
up any session.

Tables, all keyed by `connection_ref` (the ServiceConnection public id):

- `sessions`: provider, the encrypted session (Telethon: auth key, DC, and the
  entity cache with access hashes; whatsmeow: its sqlstore rows), update state
  (pts/qts/date/seq, and per-channel pts), status.
- `session_leases` (§2.1).
- `peer_messages`: (connection_ref, message_id) → typed peer, for non-channel
  messages only. Telegram numbers DM and basic-group messages in one
  account-wide sequence, and `UpdateDeleteMessages` carries ids without a peer
  (§7). Pruned on the same retention as Rails' messages.
- `sends`: random_id and dedupe key per house send id, written before
  dispatch (§8).
- `callback_secrets`: the per-connection secret for signing events to Rails
  (§5), encrypted.

Encryption: secret columns are AES-GCM under a key derived per connection,
HKDF(`COMMS_STORE_KEY`, connection_ref), as in the WhatsApp proposal.
`COMMS_STORE_KEY` is an accessory secret. Telethon gets a custom `Session`
subclass over this store (Telethon's session interface is designed to be
replaced); whatsmeow gets the same through `sqlstore.NewWithDB` against
Postgres. That's the same idea as the WhatsApp proposal's SQLCipher, without
tying a session to a file.

Backups: the connector database goes into the house's encrypted backups as
its own dump, still encrypted at the column level. Restoring requires
`COMMS_STORE_KEY`, which is escrowed like other deployment secrets. Recovery
check: restore into a scratch database and decrypt one session with a test
key. This never runs a restored session against Telegram while the original
is live.

## 4. Who is live

v1 has no event wakes. Residents read when asked. So most accounts don't
need a socket all day.

- **Live**: accounts with a login in progress, a pending send, or a
  read/search in the last N minutes (start at 30). These are held connected
  and receive updates in real time.
- **Idle**: everything else. Each idle account is brought live on a
  schedule (start at every 15 min, jittered). It catches up with
  `updates.getDifference`, which Telegram provides for exactly this,
  pushes events, and goes idle again. If Telegram answers
  `differenceTooLong`, the connector falls back to bounded per-chat history
  for the synced chats and records the gap in sync status.
- **On demand**: a read or search on an idle account claims it at once.

Every chat's sync status carries `synced_through`, so a resident sees how
fresh the data is instead of assuming it's live. If event wakes come later
(a Telegram DM waking a resident), the affected accounts move to "live" by
policy. The design doesn't change, only the live count.

## 5. Bootstrap, and Rails ↔ connector

This settles the WhatsApp proposal's open §2 "secret bootstrap" for both
providers:

- **Rails → connector** commands are signed with a connector-wide key,
  `COMMS_COMMAND_KEY`. Rails and the accessory both hold it as a deployment
  secret. It is never in any resident's manifest. Commands carry the
  connection ref inside the signed material, so a command for A cannot act on
  B.
- **Connector → Rails** events are signed per connection, as now
  (`CommsSignature`). The per-connection callback secret is created by Rails
  with the connection. Rails hands it over once, inside the signed
  `start_login` (Telegram) / `start_pairing` (WhatsApp) command, over the
  private network. The connector stores it encrypted (§3). A rotate command
  replaces it.
- **Resident manifests** contain the read/search/send endpoints and the
  resident's own grant, never the callback secret or any connector key. A test
  asserts this for every comms provider. The current `credential_payload`
  holds `callback_secret`, so `runtime_credentials`' connector branch must keep
  excluding it.
- **Commands** (Telegram): `start_login`, `submit_password`, `cancel_login`,
  `logout` (revokes the session at Telegram with `auth.logOut`, then deletes
  it locally), `search`, `send`, `rotate_secret`. They are synchronous with
  bounded timeouts; long work (backfill, catch-up) reports through events.

## 6. Telegram specifics

### 6.1 Application credentials

The house registers **its own** Telegram application at my.telegram.org
under a house-controlled phone number (Daniel's task). It supplies `TELEGRAM_API_ID`
and `TELEGRAM_API_HASH` as accessory secrets. Every user signs in through the
house application, which is how third-party clients work. No personal
api_id/api_hash ships. The Dell PA client's credentials and its git-synced
`.session` are never copied into the house. Development and CI use fake
credentials and the fake connector. Manual connector testing uses Telegram's
test DCs. Reference: https://core.telegram.org/api/obtaining_api_id. Telegram
monitors unofficial clients, and normal use is not a zero-ban-risk guarantee.

### 6.2 Login

QR login with 2FA is the complete v1 path. Phone and code is a named fallback,
built only if QR proves insufficient.

1. The owner presses Connect. Rails creates the ServiceConnection
   (`pairing`) and sends `start_login`.
2. The connector calls `auth.exportLoginToken` (Telethon `qr_login`). It
   pushes `login.qr` events (a `tg://login?token=…` URL, `issued_at`,
   `expires_at`) and renews each one as it expires. Rails reuses the
   existing `pairing_qr` columns and ordering rule: an older code never
   replaces a newer one.
3. If the account has 2FA, the connector pushes `login.password_required`
   (with Telegram's hint, which is not secret). The owner's page shows a
   password form. The password goes in one owner-only POST, which Rails
   forwards in `submit_password` without persisting it. The connector does
   SRP (`auth.checkPassword`) and drops it. "Not stored" covers DB columns,
   ActiveJob arguments (the forward is synchronous in the request, not a
   job), request logs (`filter_parameter_logging`), Honeybadger context,
   connector logs, and core dumps (`--ulimit core=0`). A canary test
   greps all of them.
4. On success the connector pushes `status.changed: connected` along with the
   Telegram identity (user id, display name, @username). Rails shows that
   identity on the connection page.
5. Failures are typed events: `login.expired`, `login.password_invalid`,
   `login.flood_wait(seconds)`, `login.failed(code)`. Never with secrets.
   Cancel sends `cancel_login`.

Tests cover QR expiry and renewal, cancel mid-QR, required 2FA, wrong password,
FloodWait during login, and the canary.

### 6.3 Disconnect and revocation

Disconnecting in the house sends `logout`. That calls `auth.logOut`, so the
session disappears from Telegram's Active Sessions, then deletes it from the
store. If the user terminates the session from their phone, the connector sees
`AUTH_KEY_UNREGISTERED`, pushes `status.changed: logged_out`, and Rails moves
the connection to `reauthorizing`, as for WhatsApp.

## 7. Reading: identity, edits, deletes, scope

- **Chat ids** are typed peers: `user:<id>`, `chat:<id>`, `channel:<id>`.
  Access hashes stay in the connector.
- **Message uniqueness** moves from `(service_connection_id,
  provider_message_id)` to `(comms_chat_id, provider_message_id)`. That
  matters because channel/supergroup ids collide with the account-wide
  DM/basic-group sequence. It's harmless for WhatsApp.
- **Edits**: a `message.edit` event replaces body/caption and sets
  `edited_at`. Ordered by Telegram's `edit_date`, so an older edit never
  overwrites a newer one.
- **Deletes**: a `message.delete` event sets `deleted_at` and blanks body and
  caption, keeping the row (the house discards and does not hard-delete).
  Non-channel deletes are resolved through `peer_messages` (§3), which
  survives restarts. Ids it can't resolve are counted in sync status as
  "deletions not applied", never guessed. Once a row has `deleted_at`, an
  upsert or backfill of the same message cannot restore its body (tested).
  What remains: earlier backups still contain the body until they rotate
  out, and audit rows for sends keep what was sent. The docs say so, and do
  not claim erasure.
- **Scope** (from the Dell digest): DMs, Saved Messages, basic groups, and
  supergroups with ≤30 members are synced. Bots and broadcast channels are
  not. Every dialog is listed. Unsynced ones carry `synced: false` and a
  reason (`broadcast_channel`, `large_group`, `bot`, `secret_chat`). Forum
  supergroups are synced, but without topic structure, and are marked
  `topics: unsupported`.
- **Backfill** on connect: the last 30 days, or 500 messages per synced chat,
  whichever is smaller, paginated, with coverage shown as `history_from`.
  This is not a claim to hold the complete archive.
- **Media**: kind and caption only, labelled. Downloading, transcribing and
  sending attachments are follow-ups.
- **Search**: a `search` command runs Telegram's server-side search (per-chat
  `messages.search`, or `messages.searchGlobal` restricted to synced peers)
  with a bounded limit. Results report what scope they covered. Searching
  beyond the synced scope requires an explicit `--scope all-dialogs` flag,
  which the owner must enable on the connection (default off). No index is
  added to Rails, whose bodies use non-deterministic encryption.

## 8. Sending (S3, on #264's machinery)

No parallel send path. Telegram dispatch plugs into #264's `CommsSend`, grants,
pacing and audit. That depends on #264 being reviewed and merged.

- The connector writes `(send_id, random_id)` to `sends` before calling
  `messages.sendMessage`. A retry of the same house send reuses the same
  random_id. Telegram rejects a reused random_id (`RANDOM_ID_DUPLICATE`),
  which is evidence the first attempt landed. How long Telegram remembers
  random_ids is to be verified in S3. Until then, an ambiguous timeout stays
  `unknown` and is not retried automatically.
- Success records Telegram's server message id against the house send.
- `FloodWait`, slow mode, `USER_BANNED_IN_CHANNEL`, `CHAT_WRITE_FORBIDDEN` and
  similar become truthful terminal outcomes. A delayed send rechecks the
  grant at dispatch and stays visible while it waits.
- Rate limits are per session, so one user's pace never throttles another.

## 9. Rails changes (S1)

- Catalog: `telegram`, `management_scopes: personal`,
  `connection_method: pairing`, `credential_strategy: connector`, profiles
  `read` (and `send` once #264 lands), `requires_env: COMMS_CONNECTOR_URL`.
  Account-managed is not offered for v1 (not needed). The ownership framework
  is left as is.
- Migration: the uniqueness change in §7, `edited_at`, `deleted_at`,
  `comms_chats.sync_state` (synced flag, reason, `history_from`,
  `synced_through`, unresolved-delete count), `comms_chats.kind` gaining
  `saved`, `channel`, `supergroup`.
- Events: `message.edit`, `message.delete`, `login.qr`,
  `login.password_required`, `login.*` failures, and `connected` with identity.
- Owner UI: QR, 2FA form, identity, sync status, cancel, disconnect, and
  the search-beyond-scope toggle.
- `soulshouse-comms` accepts telegram (with `search`), and the runtime notes
  in the catalog say what's synced and what isn't.
- `CommsConnector` signs commands with `COMMS_COMMAND_KEY` (§5).

## 10. Slices

- **S1 Rails** (§9), tested against a fake connector. Includes cross-account
  and revoked access, duplicate and out-of-order events, same message id in two
  peers, tombstone resurrection, the login flow, secret canaries, and browser
  coverage of connect, grants and sync status.
- **S2 connector**: Telethon worker pool, leases, store, live/idle policy,
  catch-up, backfill, search, logout. Tests use a fake MTProto layer
  (restart, lease loss, catch-up gap, FloodWait). Measure sessions per worker
  against test DCs.
- **S3 send** on #264.
- **Live acceptance** (Daniel): login, granted read, an approved test send to
  a chat he names, restart/reconnect, revoke, backup restore check. Dell
  cutover is a separate decision.

## 11. Open decisions

1. House Telegram application registration (Daniel: phone number).
2. Message retention: keep forever, or a rolling window per connection
   (owner-set)? It affects storage at scale, and what "deleted" leaves behind.
3. Egress: many accounts from one datacenter IP may draw Telegram's
   anti-spam attention. The design lets workers run behind separate egress
   addresses. Whether that's needed is unknown, and we watch rather than
   assume.
4. Mirror versus live reads. Considered: serve reads live from Telegram
   (it keeps cloud history) instead of mirroring. Rejected for v1. It would
   mean a live socket for every read, Telegram rate limits on read-heavy
   residents, behaviour different from WhatsApp (which has no server
   history), and no reads when Telegram is unreachable. The bounded mirror
   keeps reads cheap and uniform.
