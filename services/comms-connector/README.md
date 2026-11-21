# Comms connector (WhatsApp)

The house's WhatsApp connector: a private-network Kamal accessory
(`souls-house-comms-whatsapp`) holding one whatsmeow linked device per
WhatsApp `ServiceConnection`. Build steps 2 and 3 of
`docs/proposals/2026-10-09-whatsapp-connections.md` (§2, §3, §7).

Receives everything; sends one thing: a plain text message, when Rails asks
with `send_text` (below). Rails asks only for a resident the connection's
owner has granted sending, within its pacing; the connector has no switch of
its own and no house-wide one exists (removed 21 Nov 2026, #1084).

```
cmd/comms-connector/   startup: hardening, env, manager, mTLS command server
internal/command/      verifies Rails's signed commands (COMMS_COMMAND_KEY)
internal/sig/          both signatures, byte for byte with the Ruby (vectors in tests)
internal/server/       manager (start_pairing / unpair / pair_phone / send_text / boot) and the HTTP handler
internal/worker/       one connection: lease, store, session, ordered delivery to Rails
internal/rails/        signed POST /internal/comms/connections/:id/events
internal/provider/     Session/Sink seam; deterministic Synthetic provider
internal/whatsapp/     whatsmeow provider (sqlstore.NewWithDB on our *sql.DB)
internal/store/        per-connection SQLCipher store: meta, outbox, carryover, sends, whatsmeow_* tables
internal/keys/         store key = HKDF(COMMS_STORE_KEY, connection); log ids
internal/lease/        flock on <data>/.leases/<connection>, outside the deletable connection dir
internal/harden/       PR_SET_DUMPABLE=0, RLIMIT_CORE=0, umask 077, GOTRACEBACK check
```

Kept from #259: the SQLCipher store (sqlite3mc, SQLCipher v4 mode, DSN only in
a closure, temp store in memory), the lease and the process hardening.
Dropped (spec §7 step 2): tickets, the read API, the access log and the KEK
envelope. Residents read through Rails, not the connector.

## Protocol

**Rails → connector** (`app/lib/comms_connector.rb`, the same path as Telegram):
`POST /connections/<svc_id>/start_pairing`, `/unpair`, `/pair_phone` and `/send_text`, over mutual TLS
(Rails's client certificate, the connector's server certificate, one house
CA), signed with the connector-wide `COMMS_COMMAND_KEY`:

    v1 LF key-id LF connection LF operation LF command-id LF issued-at LF hex(sha256(body))

The body repeats connection, operation, command id and issue time and must
agree with the URL and headers. Refused: a bad signature, an unknown key id,
a command older than 60 s or from the future, one issued before the process
started, and a command id already seen. `start_pairing` carries the
connection's `callback_secret` and `callback_secret_version`; that is how the
connector learns the secret (the spec's open "secret bootstrap", settled as
for Telegram). An older secret version than the one held is refused (409).

The secret version is also the **pairing attempt**. Rails starts at 1 and
adds one each time the owner restarts pairing (the secret itself is kept),
and the connector stamps `"attempt": N` on every event it posts. Rails
refuses an event from any other attempt (409 `stale_attempt`, checked under
the connection's row lock); a sequenced status event from an older attempt
is acknowledged as skipped, so the outbox behind it moves on. So nothing an
earlier attempt still has in flight, such as the `connected` of a device
being deleted, can change the connection.

`start_pairing` always starts over: any previous device for the connection is
logged out (best effort) and the store is reset in one transaction (its
session tables and metadata dropped, the outbox emptied). Chats and messages
the old pairing had received but Rails had not yet acknowledged are not
dropped with it: they exist nowhere else (WhatsApp was told they were
received), so they move to a carryover table and are queued right after the
new pairing's `connected`, under the new attempt. Status events of the old
device are dropped. If the new pairing is a different WhatsApp account, those
messages still land on this connection. Then the fresh session pushes QR
codes. `unpair` logs the device out at WhatsApp (best effort, 20 s bound),
then deletes the store and the connection's directory, and only then
releases the lease. Unpairing an unknown connection succeeds.

**Pairing by phone number** (WhatsApp's "Link with phone number instead",
whatsmeow `PairPhone`), for an owner on the phone WhatsApp is on, who
cannot scan a QR on that screen. `pair_phone` carries `phone_number`
(E.164: `+`, country code, at most 15 digits; Rails normalises and checks
it, the connector checks it again) and `attempt`, a JSON integer that must
be the pairing attempt the connection is on (409 `stale_attempt`
otherwise; 409 `not_pairing` for a connection that is linked, unknown or
no longer pairing), and `request_id`, Rails' id for this one ask (16
lowercase hex characters, random, never derived from the number; 422
`bad_request_id` otherwise). It is accepted at once (202): the code follows
as an event naming the same `request_id`. With it comes `request_seq`, the
request's place in Rails' order: a positive JSON integer Rails assigns
under the connection's row lock, per connection, never reset (a restart
continues it), 422 `bad_request_seq` otherwise. Within one attempt the
owner can ask again (another number, a retry, another tab), and Rails sends
each command after recording it, so two commands can arrive in either
order: the sequence decides, not arrival. A command whose `request_seq` is
not above the highest this connection has accepted is refused, 409
`stale_request`, before anything is cancelled (Rails treats that as
harmless: its newer request is the one running); a newer one cancels the
older request, and nothing the older one still reports is sent, in
whatever order WhatsApp answers them. A command from before a restart is
refused by its attempt (409 `stale_attempt`), whatever its sequence. Rails, in turn, accepts a code or
failure only for its latest request, so a delayed or reordered answer for a
superseded one is refused (409 `stale_phone_code`) rather than shown or
allowed to clear the current code. whatsmeow can only ask for a code on a pairing connection that is
up, i.e. after its first QR, so the request waits for that (at most 30 s,
then `not_ready`); a number sent before WhatsApp has answered is fine. The
session keeps pushing QR codes meanwhile; either links. The code lives as
long as the pairing connection (160 s from its first QR); if the QR codes
run out with a code issued and unused, the connector says so (`expired`,
naming the request that got the code).
The number is passed to WhatsApp and kept nowhere: not in the store, not in
a log line (the handler logs the operation and fixed refusal words only),
and WhatsApp's own error text, which can echo it, is reduced to a fixed
word. Rails keeps the number nowhere either (`filter_parameters` covers
`phone` and `phone_number`).

**Sending a text** (`send_text`). The body carries, besides the envelope:

| Field | |
|---|---|
| `attempt` | JSON integer: the connection's current pairing attempt (as for `pair_phone`). |
| `send_id` | The house `CommsSend` id: 1–64 characters of `[A-Za-z0-9_-]`. |
| `message_id` | The WhatsApp message id, chosen by Rails in the shape the pinned whatsmeow's `GenerateMessageID` makes: `3EB0` and 16 upper-case hex digits (`^3EB0[0-9A-F]{16}$`). Passed on unchanged (`SendRequestExtra.ID`). |
| `chat` | The chat exactly as the connector reported it in its events: `<digits>@s.whatsapp.net`, `<digits>@lid` (a hidden user whose number the connector did not know) or `<id>@g.us`. No device part. |
| `text` | 1–4096 characters (code points). Sent as a plain `Conversation` message. |

Answers:

| | |
|---|---|
| 200 `{"status":"sent","message_id":…,"sent_at":…}` | WhatsApp accepted it (not delivered, not read). `sent_at` is WhatsApp's server timestamp, RFC 3339 UTC. |
| 200, the same body | This `send_id` was sent before: answered from the record, nothing sent. |
| 409 `not_connected` | A `send_id` with no record, and no live paired session for the connection. Nothing recorded or sent. |
| 409 `stale_attempt` | A `send_id` with no record, and `attempt` is not the connection's. Nothing recorded or sent. |
| 409 `outcome_unknown` | This `send_id` was attempted and its outcome never recorded (a crash, a timeout, or a duplicate request while the first is still in flight). Never sent again. |
| 422 `send_mismatch` | This `send_id` was seen with another `message_id`, chat or text, or this `message_id` with another `send_id`. |
| 422 `refused` + `reason` | Certainly not sent: `not_on_whatsapp`, `recipient_lookup_failed`, `group_lookup_failed`, `not_connected`, `bad_chat`. Answered the same on a replay. |
| 422 `bad_attempt`, `bad_send_id`, `bad_message_id`, `bad_chat`, `unsupported_chat`, `bad_text` | A field is wrong. Nothing recorded or sent. `unsupported_chat`: status updates, broadcast lists, newsletters, bots and other servers. (`attempt` that is not a positive JSON integer is refused by the verifier, 401 `bad_attempt`, as for `pair_phone`.) |
| 502 `send_unknown` | The send may or may not have gone out (a timeout, a lost connection, a server error after sending). Recorded as attempted, so never sent again. |
| 500 `send_failed` | The store failed. This can only happen before WhatsApp is asked: after the call, a failure to record the outcome is logged and the answer is still the outcome (and the row stays `attempted`, so a replay answers `outcome_unknown`). Rails treats it as unknown anyway. |

Rails treats anything else (no answer, a timeout, another status) as
unknown, and never retries a send.

**A recorded `send_id` is answered from its record first**, before the
attempt or the session is looked at: a replay of a sent, refused or
attempted `send_id` answers the identical 200, the same 422 `refused` or
409 `outcome_unknown` whether or not the connection is connected or the
attempt is current (and 422 `send_mismatch` if anything differs). Only a
`send_id` with no record goes on to `stale_attempt` / `not_connected` and
then to the attempted write.

**Durability: at most once per `send_id`.** Before WhatsApp is asked, the
connector writes `sends(send_id, message_id, chat_digest, text_digest,
state='attempted')` to the connection's SQLCipher store and commits it
(`synchronous=FULL`). The check and the write are one immediate
transaction, so of any number of simultaneous requests for one `send_id`
exactly one reaches WhatsApp. After the call the row becomes `sent` (with
`sent_at`) or `refused` (with the reason). An unknown outcome leaves it
`attempted`, and a row still `attempted` answers `outcome_unknown` for
ever, after a crash or a restart too: the connector never sends a
`send_id` twice. The digests are SHA-256 of the chat and of the text; the
text is not stored, and neither it, the chat, the message id nor the send
id appears in a log line. The record survives a restarted pairing
(`start_pairing` keeps the `sends` table) and goes with the store on
`unpair`. whatsmeow keeps a sent message for retry receipts in memory only
(`UseRetryMessageStore` stays off).

Only these whatsmeow errors count as refusals, because the pinned version
(`send.go`) returns them before any part of the message reaches the
socket: `ErrClientIsNil` and `ErrNotLoggedIn` (`not_connected`),
`ErrRecipientADJID` (`bad_chat`), "no LID found for … from server"
(`not_on_whatsapp`), the number's LID or user-info lookup failing
(`recipient_lookup_failed`), and the group's member lookup failing
(`group_lookup_failed`). They are matched on the top-level error only.
Everything else is unknown, including an error code in the server's ack.

The sent message reaches Rails like any other: when WhatsApp reports it
back as the account's own message (`IsFromMe`), it is an ordinary
`message.upsert` whose `provider_message_id` is the `message_id` Rails
chose.

**Revocation.** If the owner's disconnect cannot reach the connector, Rails
still revokes the connection (and erases the secret), keeps it marked
`unpair` pending, shows that on the owner's card, and retries `unpair` every
5 minutes (`CommsUnpairJob`) until the connector confirms. Meanwhile Rails
answers any event for a revoked connection with 410 `connection_revoked`
(before verification; it has no secret left), and the connector treats that
as an unpair: it stops the session, logs the device out and deletes the
store.

**Connector → Rails**: `POST COMMS_RAILS_URL/internal/comms/connections/<svc_id>/events`,
signed with the connection's callback secret (`CommsSignature`):

    connection LF METHOD LF path LF unix-seconds LF nonce LF raw-body

Events: `pairing.qr` (code, `issued_at`, `expires_at`; sent at once, never
stored, retried only until it expires); `pairing.phone_code` (the same
shape, the code as `XXXX-XXXX`, plus `request_id`) and
`pairing.phone_code_failed` (`reason`: `phone_invalid`, `rate_limited`,
`not_ready`, `expired` or `failed`, plus `request_id`), sent like a QR; and, through the store's outbox,
`status.changed` (`connected` with identity, `logged_out`), `chat.upsert` and
`message.upsert` (batches of ≤ 200 and ≤ 512 KiB; a body or caption past
64 KiB is cut). Outbox events carry a sequence number; Rails applies them
exactly once and in order and acknowledges the highest it committed, and only
then does an event leave the outbox. A fresh store learns where Rails is from
a deliberate `sequence_gap` reply. An event Rails refuses as invalid (422) or
too large (413) five times in a row is dropped so it cannot block the rest.
"In a row" is literal: any other outcome between refusals (Rails unreachable,
another status) starts the count again, and the count is held in memory, so
a connector restart starts it again too. What is dropped is the whole event,
which is a batch of up to 200 chats or messages, valid ones included; the
outbox does not split a batch Rails refused.

whatsmeow acknowledges a message to WhatsApp only after it is in the outbox
(`SynchronousAck`).

## Build and test

cgo is required, and the build must define `SQLITE_TEMP_STORE=3`; the store
refuses to open otherwise.

```sh
make test      # CGO_ENABLED=1 CGO_CFLAGS="-O2 -g -DSQLITE_TEMP_STORE=3" go test -count=1 ./...
make build     # bin/comms-connector
```

The Rails ↔ connector end-to-end test runs the real binary against a real
Rails server (synthetic provider, real mutual TLS, real signatures, real
events endpoint, unpair deleting the store, and the §3 log canary on both
sides). It is skipped unless `COMMS_CONNECTOR_BIN` names a built binary:

```sh
make build
COMMS_CONNECTOR_BIN=services/comms-connector/bin/comms-connector \
  bin/rails test test/integration/comms_whatsapp_connector_e2e_test.rb
```

## Environment

| Variable | |
|---|---|
| `COMMS_STORE_KEY` | base64 of 32 random bytes. Each connection's SQLCipher key is HKDF-SHA256(it, "comms-sqlcipher-v1" ‖ 0 ‖ connection). Losing it means re-pairing, not losing history (messages live in Rails). |
| `COMMS_COMMAND_KEY` | The same value as Rails's `COMMS_COMMAND_KEY`; at least 32 characters. |
| `COMMS_COMMAND_KEY_ID` | Default `k1`, as Rails. |
| `COMMS_RAILS_URL` | Rails's private origin, e.g. `http://souls-house-web:3000`. No path. |
| `COMMS_TLS_CERT`, `COMMS_TLS_KEY` | The connector's server certificate (SAN `souls-house-comms-whatsapp`) and key. |
| `COMMS_TLS_CLIENT_CA` | The house CA that signed Rails's client certificate. |
| `COMMS_TLS_CLIENT_NAME` | Optional; the client certificate's CN or DNS SAN that is accepted (`rails`). |
| `COMMS_LISTEN` | Default `:8443`. |
| `COMMS_DATA_DIR` | Default `/data` (the `comms` volume). |
| `COMMS_PROVIDER` | `whatsapp` (default) or `synthetic` (refused unless `COMMS_ALLOW_SYNTHETIC=1`). |
| `COMMS_SYNTHETIC_SEND` | Synthetic provider only: unset (a send succeeds and is echoed back as a received message), `refuse` (`not_on_whatsapp`), `unknown` or `hang`. |
| `GOTRACEBACK` | Must be unset or `none`. |

The binary refuses to start, logging a fixed reason and no value, if any of
these is missing or malformed.

## Deploying

Nothing deploys this automatically. `config/deploy.yml` adds the
`comms-whatsapp` accessory, the Rails settings and the TLS mount only when
`HOUSE_COMMS_WHATSAPP_IMAGE` is set in `config/house.env`; until then the
WhatsApp integration stays hidden (its catalog entry requires
`COMMS_WHATSAPP_CONNECTOR_URL`, `COMMS_COMMAND_KEY` and the three
`COMMS_CONNECTOR_*` TLS files).

1. **Check WhatsApp's current limits first** (spec §5): linked devices per
   account, the 14-day phone-offline logout, history on a new device.
2. **Image.** Pin both base images in `Dockerfile` by digest, then
   `docker build -t <registry>/souls-house-comms-whatsapp services/comms-connector`
   (the build runs `go vet` and the tests), push, and note the digest.
3. **TLS material** in one host directory (e.g. `/srv/souls-house/comms-tls`,
   mode 0700), mounted read-only into web/jobs at `/rails/comms-tls` and into
   the accessory at `/tls`:
   ```sh
   cd /srv/souls-house/comms-tls
   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
     -subj "/CN=souls.house comms CA" -keyout ca.key -out ca.pem
   openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=souls-house-comms-whatsapp" \
     -keyout connector.key -out connector.csr
   openssl x509 -req -in connector.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 825 \
     -extfile <(printf "subjectAltName=DNS:souls-house-comms-whatsapp\nextendedKeyUsage=serverAuth") -out connector.pem
   openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=rails" -keyout rails.key -out rails.csr
   openssl x509 -req -in rails.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 825 \
     -extfile <(printf "extendedKeyUsage=clientAuth") -out rails.pem
   ```
   Move `ca.key` off the host afterwards. The files must be readable by the
   containers' users (Rails's `rails` user; the connector runs as 65532).
4. **Secrets** in `.kamal/secrets`: `COMMS_WHATSAPP_STORE_KEY` (`openssl rand -base64 32`; the accessory sees it as `COMMS_STORE_KEY`)
   and `COMMS_COMMAND_KEY` (`openssl rand -hex 32`). Telegram's connector, when
   it exists, uses the same `COMMS_COMMAND_KEY` and client certificate.
5. **`config/house.env`**: `HOUSE_COMMS_WHATSAPP_IMAGE`,
   `HOUSE_COMMS_WHATSAPP_DIGEST` (`sha256:…`), `HOUSE_COMMS_TLS_DIR`.
6. `bin/kamal accessory boot comms-whatsapp`, then deploy the app so web/jobs
   pick up the new env and mount. WhatsApp then appears on the owner's
   integrations page.
7. Log smoke test before the real pairing (§3): boot a second, throwaway
   container of the same image with `COMMS_PROVIDER=synthetic
   COMMS_ALLOW_SYNTHETIC=1 COMMS_SYNTHETIC_MARKER=CANARY-…` against a staging
   Rails, or run the end-to-end test above, and grep both logs.

## Not yet proven

- Pairing with a real phone, real history sync, live messages, the
  phone-side logout and `Logout` reaching WhatsApp have not run against
  WhatsApp. They are tested only through the synthetic provider and through
  whatsmeow's store and event types offline.
- Pairing by phone number has not run against WhatsApp either: the order
  (first QR, then `PairPhone`), the error words and the expiry are tested
  with a fake `PairPhone` on a driven QR channel, and the command and events
  end to end with the synthetic provider. Whether WhatsApp accepts the
  "Chrome (Linux)" display name, how long a code really lasts, and whether
  the phone shows a notification for it are unverified.
- Group names come from a `GetGroupInfo` call per chat per run; untested
  online.
- Sending has not run against WhatsApp. Tested: the store, the worker and
  the handler with the synthetic provider (including a real process exit
  between the attempted record and the answer), and the refusal mapping
  against the real `SendMessage` offline (no socket). Untested: a send
  that WhatsApp accepts, the server timestamp, sending to a `@lid` chat and
  to a group, the server's error codes, and whether WhatsApp reports our
  own sent message back to this linked device at all (it is normally
  shown on the account's other devices; the connector handles it if it
  comes).
- Media are never downloaded (milestone 1): a message records the kind and
  caption.
- The Docker image has not been built here (no Docker in this environment).
