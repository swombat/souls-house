# Personal Telegram connections, and a comms connector built for many users

## Status, 2026-10-26

Written for the daily tidy-up (souls.house YZxxpj) by Lume. This document is
the record of a reviewed design, not a plan being executed as written. Mira
reviewed 251a068 and re-reviewed ff8a543c on PR #293; both are answered in the
text below.

What has shipped on master since the design was written:

- **S1 Rails** (§9): merged as #326 (dee0569a), tested against a fake
  connector as planned.
- **S2a**: `services/telegram-connector`, a single Telethon process run as a
  private-network Kamal accessory, holding the Telegram user sessions of
  Telegram `ServiceConnection`s. Read and bounded search only; there is no send
  endpoint (§5, §5a, §6.2, §6.3, §7). Its README names this document as its
  source. Live-updating integration summaries landed with #434.
- **The shared comms connector** (`services/comms-connector`, Go/whatsmeow)
  carries WhatsApp: one worker per connection with a durable sequenced outbox
  to Rails, an mTLS command server, phone-number pairing (#357) and gated
  sending.

Not built, and deferred rather than dropped: the pool of workers each holding
many sessions (§2), Postgres leases with fencing tokens (§2.1), fair per-tenant
scheduling (§4), the retention gate and the capacity evidence (§12), and S3
send for Telegram (§8). Those are the parts that take the design to about
1,000 connected users; what shipped is the single-process version of it. They
start when Daniel decides the connected-user count calls for them, and this
document is where that work begins.

Disposition proposed on 2026-10-26: merge this document as the record of the
reviewed design, or close #293 with this section pasted as the closing note.
Either is a decision for Daniel; nothing here asks for further amendments.

Status: design for review (Lume, 2026-10-11; amended 2026-10-12 for Mira's
review of 251a068: §2.1 fencing, §4 scheduling, §5 transport, new §5a
delivery, §3 WhatsApp storage, §1 and new §12 capacity). Brief: Mira in wJVAWj, from
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

Rough load. These are hypotheses for S2 to test (§12), not conclusions:

- Synced scope per user (see §6) is DMs, Saved Messages and small groups.
  Assuming an average of 100–500 messages a day per user, that is
  100k–500k `comms_messages` rows a day at 1,000 users, or 35M–180M a year.
  An index makes reads by chat fast; it does not make that volume
  affordable in storage, vacuum or backup time. Retention is therefore a
  gate (§11.2, §12): it is decided, with measured row growth, before the
  connection is offered to anyone beyond Daniel, and before 100 accounts.
- Event ingestion is signed batches of up to 200 (`CommsEvents::MAX_BATCH`).
  That caps batch size; it does not set the request count, which depends on
  how bursty updates are. Live sessions deliver small batches often. S2
  measures requests per account per hour and Rails ingest latency under load.
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

### 2.1 The invariant: one live client per session

A Telegram auth key (and a whatsmeow device) must never be live in two places
at once. That is the real constraint behind "one worker per connection".

A database lease cannot enforce this on its own (Mira, review of 251a068).
Telegram never sees our fencing token. A worker can pass a fence check,
pause, lose its lease, and resume straight into an RPC, and Telethon's
background pings and acks are not covered by any check at all. So the lease
records ownership, and the invariant is enforced by *stopping the old owner*:

- `session_leases(connection_ref, worker_id, fence, renewed_at, state)`.
  `worker_id` names a process instance: host, container id and a random
  boot nonce. Claims are conditional updates that increment `fence`; the
  fence still guards every store write, so a stale owner cannot write.
- **Clean handoff**: the owner disconnects the client, waits for the socket
  to close, then sets the lease `released`. Only a `released` lease, or one
  that was never held, can be claimed without further checks.
- **Uncertain loss** (renewal stopped: crash, pause, partition): expiry
  alone never authorises a new client. The lease moves to `suspect`. A
  supervisor on the owner's host (one small process per host, holding the
  Docker socket) kills the worker's container and confirms it has exited,
  then marks the lease `fenced`. Only a `fenced` lease can be claimed.
  Killing the whole worker is deliberate: it is the only stop that also
  stops background network activity.
- **Cannot confirm** (the host is unreachable, or the supervisor is down):
  the lease stays `suspect`, and every connection on it shows as
  `unavailable` in Rails with the reason. A host that comes back with a new
  boot id counts as confirmed stopped. Otherwise an operator confirms by
  hand. This trades availability for the invariant on purpose.
- **Defence in depth, not the guarantee**: each worker runs a loop-lag
  watchdog. If the event loop was stalled past half the renewal window, the
  worker's first action on resume is to disconnect every client and re-check
  its leases before reconnecting any.
- Assignment stays claim-on-demand under the scheduler in §4. There is no
  coordinator for assignment; the per-host supervisor only stops processes.

Tests (S2, fake MTProto): SIGSTOP a worker past expiry, then SIGCONT; drop
its database connection while its Telegram socket stays up; let a lease
expire during an in-flight RPC. In each case, no second client for that
session connects until the old container is confirmed exited, and the
connection reports `unavailable` meanwhile.

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
  (§5), encrypted, with a version number.
- `outbox` (§5a): events for Rails, in order, with a delivered mark.
- `work_items` (§4): due and pending work per connection, with
  `not_before` for FloodWait.
- `command_nonces` (§5): recent command ids, for replay rejection.

Encryption: secret columns are AES-GCM under a key derived per connection,
HKDF(`COMMS_STORE_KEY`, connection_ref). `COMMS_STORE_KEY` is an accessory
secret. Telethon gets a custom `Session` subclass over this store (Telethon's
session interface is designed to be replaced), which encrypts the auth key and
entity cache before they reach Postgres.

WhatsApp is **not** covered by this paragraph. An earlier draft said
`sqlstore.NewWithDB` gives whatsmeow the same thing. It doesn't: that call
chooses a database backend and stores device keys in plain columns. Moving
WhatsApp off SQLCipher would need an encrypting implementation of whatsmeow's
store interfaces, plus a migration and compatibility gate. That belongs in the
WhatsApp proposal. This document shares the fleet, lease and protocol
principles with WhatsApp, not a storage implementation. Telegram does not wait
on any WhatsApp redesign.

Backups: the connector database goes into the house's encrypted backups as
its own dump, still encrypted at the column level. Restoring requires
`COMMS_STORE_KEY`, which is escrowed like other deployment secrets. Recovery
check: restore into a scratch database and decrypt one session with a test
key. This never runs a restored session against Telegram while the original
is live.

## 4. Who is live, and how work is scheduled

v1 has no event wakes. Residents read when asked. So most accounts don't
need a socket all day.

- **Live**: accounts with a login in progress, a pending send, or a
  read/search in the last N minutes (start at 30). These are held connected
  and receive updates in real time.
- **Idle**: everything else. Each idle account is brought live on a
  schedule (start at every 15 min, jittered). It catches up with
  `updates.getDifference`, which Telegram provides for exactly this,
  plus `updates.getChannelDifference` for each synced supergroup (each has
  its own pts), pushes events through the outbox (§5a), and goes idle
  again. If Telegram answers `differenceTooLong` (account or channel), the
  connector falls back to bounded per-chat history for the affected synced
  chats and records the gap in sync status.
- **On demand**: a read or search on an idle account asks for it to be
  brought live. It is served if capacity allows within the request's
  timeout; otherwise the caller gets a truthful `busy` with `retry_after`,
  never a hang.

Every chat's sync status carries `synced_through`, so a resident sees how
fresh the data is instead of assuming it's live. `synced_through` only moves
when Rails has committed the events it covers (§5a). If event wakes come later
(a Telegram DM waking a resident), the affected accounts move to "live" by
policy. The design doesn't change, only the live count.

### 4.1 Scheduling and overload

All of this lives in the connector's Postgres. No broker is needed.

- **Routing.** Rails sends commands to one private address. Any worker can
  take a command. It looks up the lease: if it holds it, it runs the command;
  if another worker holds it, it forwards to that worker's address from the
  lease row; if nobody does, it claims it within capacity or answers `busy`.
- **Durable work.** Catch-ups, backfill pages, renewals of a login QR and
  delayed retries are rows in `work_items` (connection, kind, class,
  due_at, not_before, attempts). Workers claim due rows for connections
  they own, or connections they can claim. A worker restart loses no
  scheduled work.
- **Three classes.** `interactive` (reads, search, send, login steps),
  `catch_up` (scheduled idle sync) and `bulk` (onboarding backfill).
- **Fair admission between tenants.** Every class admits work per account,
  round-robin across the accounts that have work waiting, never first come
  first served across the pool. Interactive work also has a per-account
  concurrency limit and a token bucket, so one busy tenant gets its share
  and then waits, while other tenants' first requests go ahead of its
  backlog.
- **Guaranteed background progress.** Each worker reserves a share of its
  capacity for each class (start: interactive 25%, catch-up 20%, bulk 10%;
  the rest is shared). Under sustained interactive demand, catch-up and bulk
  still progress at their reserved rate. A catch-up overdue by more than
  twice its interval is promoted ahead of shared-capacity interactive work.
  `catch_up` is otherwise oldest-due-first; `bulk` goes one page per account
  per turn.
- **Bounds.** Per worker: max live sessions, max concurrent catch-ups, max
  concurrent backfill pages. Per account: one operation in flight per class,
  and an onboarding budget for the whole account (start at 5,000 messages
  across all synced chats), not only per chat.
- **FloodWait is per account and per method class**, stored as
  `not_before` on that account's work, for reads, search and catch-up as
  well as sends. No worker-wide sleep. A command that hits it answers with
  the wait, truthfully.
- **Restart bursts.** A starting worker claims leases through a token
  bucket (start at 5 connects a second per worker) with jitter, and a
  pool-wide cap on new connections per second, so a full restart doesn't
  reconnect 1,000 sessions at once.
- **Saturation is visible.** Rails shows `queued` or `busy` on the
  connection, with the queue age, instead of a stale `synced_through`
  silently growing old.

## 5. Bootstrap, and Rails ↔ connector

This settles the WhatsApp proposal's open §2 "secret bootstrap" for both
providers.

Signing authenticates a command but does not hide it, and some commands carry
a callback secret, a QR token or a 2FA password. So:

- **Confidential transport.** Rails ↔ connector traffic is mutual TLS over
  the private network, with a house-internal CA. Rails and each worker hold
  their own certificate and key as deployment secrets. Plain HTTP is
  refused. Secrets in bodies are therefore encrypted in transit, and both
  ends are authenticated.
- **Authenticated, fresh, bound commands.** On top of TLS, each command is
  signed with `COMMS_COMMAND_KEY` (with a key id). The signed material
  includes connection ref, operation, a unique command id, an issued-at
  time and, for login commands, the `login_generation`. The connector
  rejects commands older than 60 s, any command id already seen
  (`command_nonces`, kept longer than the freshness window), and a key id it
  doesn't know.
- **Login generations.** Rails increments `login_generation` on every
  start or cancel. The connector stores the current generation per
  connection. A `start_login` at or below it is refused, so a delayed or
  replayed start cannot reopen a cancelled login. `submit_password` must
  match the current generation exactly.
- **Callback secret versions.** The secret travels with a version number.
  The connector never installs a version lower than the one it holds, so a
  replayed old command cannot restore an obsolete secret.
- **Key rotation.** Command keys and TLS certificates have ids. During a
  rotation both sides accept the current and the previous id, then the old
  one is dropped. Rotation is a documented runbook with a test.
- **Redaction.** The connector never logs request bodies. Secret fields are
  held in a wrapper type whose string form is `[redacted]`. Rails filters
  the same parameter names. The canary test in §6.2 covers both.
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
  `submit_password` stays synchronous inside the owner's request: the
  password is never queued, on either side.

## 5a. Durable delivery to Rails

A crash must not advance Telegram progress while losing the house's copy of
what that progress covered.

- **Ingest atomically.** When the connector processes an update batch (live
  updates or a difference), it writes the derived events to `outbox` *and*
  the new update state (account pts/qts/date/seq, or that channel's pts) in
  one transaction. The custom Telethon session does not persist update state
  on its own schedule; state is saved only in that transaction. If the
  process dies before the commit, Telegram replays the same updates on the
  next difference. S2 has to verify the Telethon hooks that make this
  possible. If they don't hold, the connector runs its own difference loop
  instead of Telethon's update handling.
- **Deliver with acknowledgement.** A sender per connection posts outbox
  events to Rails in order. Rails' ingest is idempotent (message keys, edits
  ordered by `edit_date`, tombstones that can't be undone) and answers with
  the highest event sequence it committed. Only then does the connector mark
  those rows delivered. Retries resend the same sequence numbers.
- **Checkpoints travel as events.** `synced_through` reaches Rails as a
  `sync.checkpoint` event queued after the events it covers, so Rails can
  never show a checkpoint ahead of the data.
- **Bounded, with backpressure.** The outbox is capped per connection (start
  at 10,000 undelivered events or 7 days). At the cap the connector stops
  taking updates for that connection at all, live ones included: it
  disconnects that connection's live client and schedules no catch-up until
  the outbox drains below a low-water mark (start at half the cap). Because
  update state is persisted only together with outbox rows, disconnecting
  never moves progress past an undelivered event; the updates wait at
  Telegram for the next difference. Reads keep working from the mirror.
  The connection shows `backlogged` with the outbox age. If the difference
  later comes back too long, the per-chat history fallback in §4 applies,
  with the gap recorded.
- **Recovery tests**: kill between outbox commit and delivery; kill between
  Rails commit and acknowledgement; a Rails outage longer than the cap;
  per-channel recovery after a `channelDifferenceTooLong`.

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
- `CommsConnector` talks mutual TLS, signs commands with `COMMS_COMMAND_KEY`
  (key id, command id, issued-at), and keeps `login_generation` and the
  callback secret version per connection (§5).
- Ingest answers with the highest committed event sequence, and accepts
  `sync.checkpoint` events (§5a). Connection status gains `queued`, `busy`,
  `backlogged` and `unavailable`, each with a reason (§2.1, §4.1).

## 10. Slices

- **S1 Rails** (§9), tested against a fake connector. Includes cross-account
  and revoked access, duplicate and out-of-order events, same message id in two
  peers, tombstone resurrection, the login flow, secret canaries, and browser
  coverage of connect, grants and sync status.
- **S2 connector**: Telethon worker pool, leases with the per-host
  supervisor (§2.1), store, outbox (§5a), scheduler (§4.1), catch-up,
  backfill, search, logout. Tests use a fake MTProto layer (pause/resume,
  partition, lease expiry mid-RPC, crash between outbox and delivery,
  catch-up gap, FloodWait). The load test in §12.
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

## 12. Capacity evidence (S2)

Target: 1,000 connected accounts without redesign. 10,000 is a separate
capacity exercise, and nothing here claims it.

The S2 load test runs the pool against a fake MTProto layer that injects
realistic update traffic and FloodWaits (Telegram's test DCs prove mechanics,
not production rate limits or anti-abuse thresholds). Scenarios:

- 1,000 accounts, mostly idle, about 10% live. At a 15-minute sweep that
  starts about 1.1 catch-ups a second; concurrency depends on how long each
  catch-up takes, which is measured, not assumed.
- All 1,000 live at once, across the pool.
- 50 concurrent onboarding backfills.
- Rails slowed to 2 s per ingest request, then down for an hour.
- Worker restart, and full-pool restart.
- One abusive tenant: very large dialogs, constant search, repeated FloodWait.

Recorded: RSS and file descriptors per worker and per session, event-loop
lag, connector DB query latency, outbox depth and delivery lag, Rails ingest
request rate and latency, catch-up lag distribution, and recovery time after
each restart. The pool size and the per-worker bounds in §4.1 come from these
numbers.

Storage gate: row growth per account and per day is measured during Daniel's
live use. Retention (§11.2) is decided against those numbers before the
connection is offered to other users.
