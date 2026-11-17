# Telegram connector (S2a, S2b slices 1–2)

The house's Telegram connector: a private-network Kamal accessory
(`souls-house-comms-telegram`) holding the Telegram *user* sessions of
Telegram `ServiceConnection`s, so the residents an owner grants can read that
owner's Telegram through `soulshouse-comms` (Rails's comms read and search
endpoints). Slice S2a of `docs/proposals/2026-10-11-telegram-personal-connections.md`
(§5, §5a, §6.2, §6.3, §7): one process, Telethon 1.41, Python 3.13.

Read and bounded search only. There is no send endpoint, scope or code.

```
connector/__main__.py  startup: hardening, env (fails closed), lease, store, mTLS server
connector/server.py    POST /connections/<svc_id>/<op>, GET /healthz; mutual TLS only
connector/commands.py  verifies Rails's signed commands (COMMS_COMMAND_KEY)
connector/manager.py   the accounts in this process; command dispatch
connector/account.py   one account: login, sync, backfill, search, logout, delivery
connector/sync.py      Telegram data → events, committed with the progress they cover
connector/telegram.py  the Telethon side (RealTelegram, HouseSession); the seam fake.py replaces
connector/convert.py   Telegram objects → the event shapes app/lib/comms_events.rb accepts
connector/rails.py     signed, ordered delivery of the outbox to Rails
connector/store.py     the store: Postgres (production) or SQLite (tests); sealed columns (AES-GCM)
connector/storethread.py  the one thread that uses the store's connection; fail-stop watchdog
connector/migrate.py   SQLite → Postgres (and the explicit rollback), verified row by row
connector/lease.py     single ownership: flock on <data>/.owner
connector/harden.py    RLIMIT_CORE=0, PR_SET_DUMPABLE=0, umask 077
connector/fake.py      a fake Telegram for the tests and the Rails end-to-end test
```

## Protocol

**Rails → connector** (`app/lib/comms_connector.rb`, `Services::TelegramAdapter`):
`POST /connections/<svc_id>/{start_login,request_code,submit_code,submit_password,cancel_login,logout,search}`
over mutual TLS (Rails's client certificate, the connector's server
certificate, one house CA; with `COMMS_TLS_CLIENT_NAME` the client
certificate must name `rails`), signed with `COMMS_COMMAND_KEY`:

    v1 LF key-id LF connection LF operation LF command-id LF issued-at LF hex(sha256(body))

The body repeats connection, operation, command id and issue time and must
agree. Refused: unknown key id, bad signature, older than 60 s or from the
future, a command id already seen (kept in the store, so a restart does not
forget it). During a key rotation `COMMS_COMMAND_KEY_PREVIOUS(_ID)` is
accepted too.

- `start_login {generation, callback_secret, callback_secret_version}`: refused
  (409 `stale_generation`) unless the generation is above the one held, and
  (409 `stale_secret_version`) for an older secret version. Any previous
  session is logged out at Telegram (best effort) and dropped. Then QR login
  (`auth.exportLoginToken` through Telethon's `qr_login`): each code goes to
  Rails at once as `login.qr` (`code` = the `tg://login?token=…` URL,
  `issued_at`, `expires_at`, `generation`; unsequenced, never stored,
  retried only until it expires) and is renewed as it expires, for at most
  ten minutes, then `login.failed expired`. A two-step account gets
  `login.password_required` (with Telegram's hint).
- `request_code {generation, phone}`: the phone-number path, for signing in
  on the phone itself (Telegram will not approve a `tg://login` token opened
  on the device that would approve it). Only for the current generation
  while it is logging in (409 `not_logging_in` otherwise). The number must
  be international (`+` or `00`, then the country code); anything else is
  `phone_invalid` without asking Telegram. The first request ends the
  attempt's QR loop (no more `login.qr`) and starts the phone path's own
  ten-minute window, then `auth.sendCode` through Telethon's
  `send_code_request` on the same client. A second request for the same
  number resends (Telethon's `auth.resendCode`); another number starts over.
  The number and Telegram's `phone_code_hash` are held in memory for
  `submit_code` only. Replies `code_sent` with `delivery` (`app`, `sms`,
  `call`, `fragment`, `email`, `other`), and when Telegram gives them
  `length`, `next_delivery` and `timeout`; the same, without the number, is
  queued as `login.code_sent`. Or `phone_invalid`, `phone_banned`,
  `unsupported` (Telegram wants a login email set up first), `flood_wait`
  (+`retry_after`) or `failed`. If the first request sends no code, the QR
  comes back: a fresh token on the same client (Telethon's `QRLogin.wait`
  removes its handler when cancelled), within the attempt's original window,
  so the QR the owner is offered instead is live. A resend that fails leaves
  the code already sent in place. The phone path has one deadline, used by
  both its timer and `request_code`: a request that ends after it ends the
  attempt (`login.failed expired`) and replies `expired`, never `code_sent`.
- `submit_code {generation, code}`: only for the current generation after a
  code was sent (409 `not_waiting_for_code` otherwise). `auth.signIn`, then
  the code is dropped. Replies `accepted`, `password_required` (a two-step
  account: `login.password_required` follows and `submit_password` finishes
  it), `code_invalid`, `code_expired` (ask for a new one), `phone_unregistered`
  (no Telegram account for the number), `flood_wait` (+`retry_after`) or
  `failed`. The phone number and the code get the password's discipline:
  never stored, queued or logged, the body buffer zeroed, taken out of the
  command fields at once.
- Finishing a sign-in Telegram has accepted (by QR, code or password) reads
  the account's update state first. If that fails, the attempt ends cleanly
  (`login.failed failed`, the session logged out at Telegram, best effort)
  and the command replies `failed`, rather than leaving it half signed in
  with no deadline.
- `submit_password {generation, password}`: only for the current generation
  while a password is wanted. SRP (`auth.checkPassword` via Telethon's
  `sign_in(password=…)`), then the password is dropped: it is never stored,
  queued or logged, the request body buffer is zeroed, and the command
  fields lose it at once. (Python strings cannot be wiped; the process is
  non-dumpable and has no core dumps.) Replies `accepted`,
  `password_invalid`, `flood_wait` (+`retry_after`) or `failed`.
- `cancel_login {generation}`: stops the attempt (any generation at or above
  the one held), drops the half-made session.
- `logout`: `auth.logOut` at Telegram (the session leaves Active Sessions),
  then the connection's rows are deleted. Idempotent.
- `search {query, chat, limit, scope}`: Telegram's own search
  (`messages.search` in one chat, `messages.searchGlobal` filtered to the
  synced chats); `scope: all_dialogs` only if Rails allowed it. Replies
  `{coverage, results}` or `retry_after` on a FloodWait.

**Connector → Rails**: `POST COMMS_RAILS_URL/internal/comms/connections/<svc_id>/events`
signed with the connection's callback secret (`CommsSignature`). Through the
ordered outbox, with sequence numbers: `status.changed` (`connected` with the
identity, `logged_out`; always with the current generation),
`login.code_sent`, `login.password_required`, `login.failed`, `chat.upsert` (every dialog;
unsynced ones with `synced: false` and a reason), `message.upsert`,
`message.edit`, `message.delete` (non-channel deletes resolved through the
durable peer map, the rest counted as `unresolved`), `sync.checkpoint`.
Batches are at most 200 items and about 512 KiB. Rails acknowledges the
highest sequence it committed; only then are rows marked delivered. A 410 `connection_revoked` (the owner's
disconnect never reached the connector) deletes the connection, logging it
out at Telegram first. An event refused 422/413 five times in a row is
replaced in place by a no-op, so the sequence keeps no hole.

**A fresh or restored volume.** Every process, before it delivers anything,
asks Rails how far it has committed (a deliberate `sequence_gap` probe that
applies nothing). Every number the store ever issued is below the `next_seq`
it held when the process opened it. If Rails has committed a number at or
above that, the store is behind Rails: a fresh store for a connection Rails
knows, or a volume restored from an older copy. Its undelivered events are
then renumbered, in order, past Rails' sequence (logged as "store is behind
Rails"), so they are applied rather than acknowledged unseen; the restored
update state replays from Telegram what the copy had not seen (or, past
Telegram's limit, refetches the synced chats' history). No step is needed
after a restore beyond starting the connector, and signing in again is not
part of the recovery. A reply from Rails ahead of every number issued, at any
time, is never taken as delivery: the sequence is checked again first.
Tested end to end: `test/integration/comms_telegram_connector_e2e_test.rb`
restores the real process's volume from a backup while Rails keeps its data,
and every live message still arrives.

When a new attempt starts while the previous session's chats and messages are
undelivered, they would be refused (the connection is pairing) and block the
attempt's own events: they are replaced in place by no-ops and kept in a
carryover, queued again right after the new `connected`.

## Delivery guarantees (Mira's S2a boundaries)

**Single owner.** Before it opens the store or any Telegram client the
process takes an exclusive `flock` on `<data>/.owner` and holds it for its
whole life; the kernel releases it however the process ends. A second process
on the same volume (an overlapping deploy, a container started by hand)
logs `waiting for the data lease` and starts nothing — no store, no server,
no client — until the holder has exited. It then takes the store's
Postgres advisory lock (see "Store"), which makes a process on another
volume wait the same way; that lock only ever makes a process wait. Kamal runs the accessory as one
named container; `kamal accessory reboot` removes the old container before it
starts the new one. Sessions are only ever created here by QR login; the
Dell's session file is never used.

**Outbox before progress, live and backfill.** What Telethon 1.41.2 does with
its own update state (read in `telethon/client/updates.py` and
`telegrambaseclient.py`, and pinned by `tests/test_replay.py
TelethonStateTest`):

- its `MessageBox` advances pts/qts/date in memory in `process_updates` /
  `apply_difference`, *before* any event handler runs (handlers are spawned
  as tasks);
- `_save_states_and_entities` writes that in-memory state to the session
  every keepalive minute, when the entity cache fills, and on disconnect,
  whatever the handlers did;
- with `catch_up=True`, `connect()` resumes from that saved state.

So Telethon's checkpoint can run ahead of anything a handler stores: a crash,
a failed write or a refused (saturated) outbox after the minute tick loses
updates for good. The connector therefore does not use it:

- `HouseSession` persists no update state (`set_update_state` does nothing,
  `get_update_states` returns nothing) and `catch_up` is off;
- pushed updates only wake the account's own loop, which calls
  `updates.getDifference` (and `updates.getChannelDifference` for synced
  supergroups) from the state in the connector's store;
- each answer's events and the state it reaches are written in **one store
  transaction** (`sync.Ingest.commit`); the same for each backfill page and
  its cursor. Until it commits nothing moved, and Telegram replays the same
  updates.
- `flood_sleep_threshold=0`, so Telethon never sleeps through a FloodWait
  inside a call; every FloodWait reaches the caller.

**Saturation.** At `outbox_cap` undelivered events (10,000) or an oldest one
older than 7 days, sync and backfill stop fetching. Nothing is
acknowledged and no state moves; the updates wait at Telegram. Rails is told
`connector.availability: backlogged` out of band. Below `outbox_low` (5,000)
fetching resumes from the stored state and Rails is told `ok`. A restart
while saturated loses nothing (tested). A `sync.checkpoint` claims only the
start of a pass whose account and channel differences all ran to the end; a
pass cut short by saturation claims nothing.

**Backfill never starves login, logout or live sync.** Backfill is its own
task: one bounded page (100) of one chat at a time, round robin, with a pause
between pages, and it never holds the account's command lock. A FloodWait
in backfill pauses backfill for the whole account (account-level), not live
sync, search, login or logout (tested). Scope: the last 30 days, at most 500
messages per synced chat, reported as `history_from`: the 30-day cutoff when
the window ended the backfill, the oldest message fetched when the 500 cap
did (never more than what was fetched). A chat first seen by live sync wakes
the backfill worker for its history. When a gap Telegram will not replay
resets history cursors, a history page already in flight is dropped rather
than committed over the reset.

**At rest.** The session, the callback secret and every outbox/carryover body
are AES-GCM sealed under HKDF-SHA256(`COMMS_STORE_KEY`, salt
`souls-house-telegram-store-v1`, info = connection). The volume holds no
message text, name or password in clear (tested with canaries).
Nor the phone number or login code of a phone sign-in.

## Store (S2b slice 2)

The store is the connector's own Postgres database, `comms_telegram`, with
its own login role. The schema is `PG_SCHEMA` in `store.py` (the S2a tables;
sealed columns `bytea`; a `schema_version` row, and a connector refuses a
newer schema than it knows). SQLite remains for the tests, the load harness
and the migration; `COMMS_STORE=sqlite` is refused except with the fake
provider.

**Off the event loop.** The slice 1 baseline (`load/REPORT.md`) found every
store call synchronous on the loop thread: a restart froze the loop for 5.5 s
at 1,000 accounts. Now one thread, the store thread, is the only user of the
store's connection, and everything else awaits it (`storethread.AsyncStore`).
Jobs run one at a time in the order they were submitted, the order the loop
used to issue them, so the guarantees above are unchanged. Store work that
must not interleave with another coroutine's is one job: each `Ingest` is
filled and committed in one job (it reads the store as it goes), and so are
a dialog refresh, a checkpoint and a backfill page with the re-reads they
depend on. A gap reset counts itself inside its own job, so a history page
fetched before the reset and committed after it is still dropped.

One connection is also a throughput limit: a restart's store work (about 20
jobs per account) now queues instead of freezing the loop, and at 1,000
accounts it ends about 11 s after the stop, where the frozen SQLite restart
ended after about 9 s (`load/REPORT.md`, slice 2). More connections, sharded
by connection, would raise it; not built.

A submitted job always runs to its end: cancelling the coroutine waiting for
it stops the waiting, never the job, and never rolls it back. Shutdown runs
every job already queued, then closes the connection; the watchdog keeps
watching while it drains, and a drain that does not finish in 30 s fails
stop (exit 75) rather than report a clean stop. Queue wait and
execution time are recorded apart (`StoreThread.stats`, reported per phase by
the load harness): a loop that no longer stalls can still hide a queue that
does.

**Ownership until slice 3.** One accessory, one volume. The volume flock is
the guard, as in S2a. The advisory lock (`pg_try_advisory_lock`, held on the
store connection for the process's life) makes a second process on another
volume wait; it never authorises taking over. **This is not fencing.**
Postgres releases the lock as soon as it considers the connection gone, and
the old process may not know yet: its Telegram clients run until it exits.
Nothing here replaces a process on another volume or host; slice 3 brings
leases, fencing tokens and a supervisor that confirms death before transfer.

**Fail-stop.** If the store connection fails (any `psycopg.OperationalError`
or `InterfaceError`, including a server-side timeout) or goes silent, the
process exits (code 75) and never reconnects in place. The exit does not
wait on logging: a timer thread exits 0.5 s after detection whatever the
log handlers are doing (tested with another thread holding the logging lock). `unless-stopped`
(Kamal's accessory default) restarts it, and the new process takes the volume
flock and the advisory lock again before it opens any client. Detection
bounds with the defaults (`StoreThread`: heartbeat 5 s, deadline 10 s, tick
1 s; the connection: keepalives, `tcp_user_timeout` 10 s, `statement_timeout`
10 s):

| The store connection… | The process exits within |
|---|---|
| errors, while busy | the failing call (immediately) |
| errors, while idle | the next heartbeat ping: ≤ 6 s |
| goes silent (a black-holed route, a hung server), while busy | the job's deadline: ≤ 11 s after the job started |
| goes silent while idle | heartbeat + deadline + ticks: ≤ 17 s |

Until it exits, its Telegram clients may still receive updates, but nothing
it fetches can commit, so nothing durable moves and Telegram replays the same
updates to whoever owns the session next. Tested: an error, a stall and an
idle failed ping (`tests/test_store_thread.py`); on Postgres, a backend killed
while idle, a black-holed proxy (bytes swallowed, sockets kept open, no error
ever raised), and the real process exiting 75 after `pg_terminate_backend`
(`tests/test_process_postgres.py`).

**Migration** (`python -m connector.migrate`, docstring there): with the
accessory stopped, it holds `.lease`, `.owner` and the advisory lock
throughout, copies every table as bytes (nothing decrypted), compares every
row and column before committing and again after, and keeps the source
(renamed). It refuses a destination that holds anything else. At cutover
`.lease` becomes a directory in one atomic exchange (`renameat2`
`RENAME_EXCHANGE`; the path is never free, tested with an old-image process
polling through every step), so the pre-migration image refuses to start
(`reason=lease`) rather than open an empty store, and this image refuses a
volume that still has `telegram.sqlite3` or a `.lease` file. Rollback is
`postgres-to-sqlite` (same checks), never a plain restart of the old image;
migrating again after a rollback needs `empty-postgres
--yes-delete-the-postgres-copy` first.

## Test

```sh
python -m venv .venv && .venv/bin/pip install -r requirements.txt
make test PYTHON=.venv/bin/python
```

With `COMMS_TEST_DATABASE_URL` (a server and a database to administer from,
e.g. `postgresql://postgres:postgres@localhost:5432/postgres`) the Postgres
tests run on fresh databases; `COMMS_TEST_STORE=postgres` runs every Harness
test on Postgres too. CI runs both, with `COMMS_TEST_REQUIRE_POSTGRES=1`.

`tests/test_replay.py` and `tests/test_process.py` cover crashes at each
point of the ingest path (in process, and a real `os._exit` mid-transaction
through `COMMS_FAULT`, fake provider only), a Rails outage, a lost
acknowledgement, saturation with a restart, backfill resuming from its
cursor, mutual TLS refusals, the lease, and the password and message
canaries. The Rails ↔ connector end-to-end test runs the real process
against a real Rails server (fake Telegram, real mTLS, real signatures):

```sh
COMMS_TELEGRAM_CONNECTOR_PYTHON=$PWD/services/telegram-connector/.venv/bin/python \
  bin/rails test test/integration/comms_telegram_connector_e2e_test.rb
```

## Environment

| Variable | |
|---|---|
| `COMMS_STORE_KEY` | At least 32 characters (`openssl rand -base64 32`). Losing it means signing in again, not losing history (messages live in Rails). |
| `COMMS_COMMAND_KEY` | The same value as Rails's `COMMS_COMMAND_KEY`; at least 32 characters. `COMMS_COMMAND_KEY_ID` defaults to `k1`. |
| `COMMS_RAILS_URL` | Rails's private origin, e.g. `http://souls-house-web:3000`. No path. |
| `COMMS_TLS_CERT`, `COMMS_TLS_KEY` | The connector's certificate (SAN `souls-house-comms-telegram`) and key. |
| `COMMS_TLS_CLIENT_CA` | The house CA that signed Rails's client certificate. |
| `COMMS_TLS_CLIENT_NAME` | The client certificate's CN or DNS SAN that is accepted (`rails`). |
| `COMMS_LISTEN` | Default `0.0.0.0:8443`. |
| `COMMS_DATA_DIR` | Default `/data`. Holds the volume lock (`.owner`). |
| `COMMS_DATABASE_URL` | `postgresql://comms_telegram:…@souls-house-postgres:5432/comms_telegram`: the store. Required. |
| `COMMS_STORE` | `postgres` (default) or `sqlite` (refused unless the provider is `fake`; tests only). |
| `TELEGRAM_API_ID`, `TELEGRAM_API_HASH` | The Telegram application users sign in through (Daniel's existing app for now; §6.1 is overruled for S2a). Secrets only. |
| `TELEGRAM_PROVIDER` | `telethon` (default) or `fake` (refused unless `COMMS_ALLOW_FAKE=1`; tests only). |

The process refuses to start, logging a fixed reason and no value, if any is
missing or malformed. Logs are JSON lines of fixed words and a keyed log id,
never a connection id, a name, a message, a code, a phone number or a password; Telethon's
own logger is held at ERROR.

## Deploying

Nothing deploys this automatically. `config/deploy.yml` adds the
`comms-telegram` accessory, Rails's `COMMS_CONNECTOR_URL` and the TLS mount
only when `HOUSE_COMMS_TELEGRAM_IMAGE` is set; until then Telegram stays
hidden (the catalog requires `CommsConnector::TELEGRAM_ENV`).

1. **Image.** Pin both base images in `Dockerfile` by digest, then
   `docker build -t <registry>/souls-house-comms-telegram services/telegram-connector`
   (the build runs the tests), push, note the digest.
2. **TLS.** In `HOUSE_COMMS_TLS_DIR` (shared with WhatsApp: `ca.pem`,
   `rails.pem`/`.key`), add the connector's certificate:
   ```sh
   openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=souls-house-comms-telegram" \
     -keyout telegram.key -out telegram.csr
   openssl x509 -req -in telegram.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 825 \
     -extfile <(printf "subjectAltName=DNS:souls-house-comms-telegram\nextendedKeyUsage=serverAuth") -out telegram.pem
   ```
   readable by uid 65532.
3. **Database.** On the house Postgres, once:
   ```sh
   bin/kamal accessory exec postgres --interactive --reuse "psql -U souls_house -d postgres"
   CREATE ROLE comms_telegram LOGIN PASSWORD '<openssl rand -base64 32>';
   CREATE DATABASE comms_telegram OWNER comms_telegram;
   REVOKE ALL ON DATABASE comms_telegram FROM PUBLIC;
   ```
   The connector's role owns only its database and has no grant on Rails's.
   Rails's role is the cluster's superuser, so it *could* read
   `comms_telegram`; what it would find there is sealed under
   `COMMS_STORE_KEY`, which Rails does not hold.
4. **Secrets** in `.kamal/secrets`: `COMMS_STORE_KEY`, `COMMS_COMMAND_KEY`
   (shared with WhatsApp if it runs), `TELEGRAM_API_ID`, `TELEGRAM_API_HASH`,
   `COMMS_DATABASE_URL`.
5. **`config/house.env`**: `HOUSE_COMMS_TELEGRAM_IMAGE`,
   `HOUSE_COMMS_TELEGRAM_DIGEST`, `HOUSE_COMMS_TLS_DIR`.
6. `bin/kamal accessory boot comms-telegram`, then deploy the app. Telegram
   appears on the owner's integrations page; the owner connects with a fresh
   QR scan and grants residents.

**Moving a running S2a connector to Postgres** (slice 2): steps 3 and 4,
then, with the new image's digest in `config/house.env`:
```sh
bin/kamal accessory stop comms-telegram
docker run --rm --network kamal -v comms_telegram:/data -e COMMS_DATABASE_URL \
  <image>@<digest> python -m connector.migrate sqlite-to-postgres
bin/kamal accessory reboot comms-telegram
```
The migration prints counts per table and, per connection, outbox rows,
highest sequence and `next_seq`; keep that output. Rollback: stop the
accessory, `python -m connector.migrate postgres-to-sqlite` the same way,
then boot the previous image's digest.

## Not yet proven

- Nothing here has talked to Telegram. Login, getDifference, channel
  differences, history, search and logout run against `fake.py`, which
  answers with Telethon's real TL types; the `RealTelegram` wrapper itself is
  untested against Telegram's servers.
- Telethon's QR wait depends on its own update loop receiving
  `UpdateLoginToken`; that is Telethon's documented path, not exercised here.
- The Docker image has not been built here (no Docker in this environment);
  the pinned requirements were installed from PyPI into a fresh 3.13 venv and
  the tests passed there.
- Secret chats are not readable (Telethon has no support); forum topics are
  flattened.
- S2b: slice 1 (the load harness and its baseline) and slice 2 (this store)
  are built; leases with fencing, the supervisor, multiple workers and
  fairness are not.
- The Postgres store has no backup of its own yet (S2a's SQLite volume had
  none either): an encrypted dump and a test-key restore come in the next
  pull request of slice 2.
