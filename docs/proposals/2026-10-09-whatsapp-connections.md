# WhatsApp connections: milestone 1 (Daniel's own number)

Status: **proposal.** Revision 4. Revision 3 (re-scoped after Daniel's
correction in OjyBlJ, reviewed by Mira in RjpvrY) is implemented as far as the
Rails read slice (#260). Revision 4 adds **sending** to milestone 1 at Daniel's
request (OjyBlJ, 2026-10-09: "I do want to be able to send WhatsApp messages
too... just like we do on the mac and dell"), as §5. Deploy remains Daniel's
call.

## The scope correction

Revisions 1 and 2 took a line meant for residents' own correspondence ("messages
between a resident and a third party must not be easy for Daniel or any house
user to read") and applied it to **Daniel's own WhatsApp**. That produced a
private runtime: a `comms` wake kind, audience gates, single-use tickets,
access epochs, a hash-chained access log, KEK escrow. Every piece of it existed
to hide Daniel's messages from Daniel's own account. Nobody asked for that, and
the house doesn't do it for his Gmail, Calendar or Drive. All of it is cut. The
earlier revisions are in this file's git history.

For a connection a human owns, the privacy requirement is the Gmail one: the
owner's data, read by the residents the owner has granted, in whatever session
or room they are working in.

The resident-owned case (a resident's own number) is a separate milestone that
starts from that confidentiality line. The SQLCipher probe in
`docs/proposals/evidence/2026-10-09-whatsmeow-sqlcipher/` stays for it.

## 1. Model: the existing service-connection pattern

A WhatsApp connection is a `ServiceConnection` with `provider: "whatsapp"`
(later `"telegram"`), registered in `Services::Catalog` like `oura` or `github`:

- `management_scopes: %w[personal]` for milestone 1. Daniel connects it and
  manages it, through `ServiceConnection#manageable_by?` as for his other
  personal connections. `account_managed` (a company number) comes later.
- `connection_method: "pairing"`, a new value: the owner scans a QR code instead
  of OAuth or a pasted credential.
- `credential_strategy: "connector"`, a new value: the WhatsApp session lives in
  the connector (§2), never in Rails. `credential_payload` (already `encrypts`)
  holds only the connector callback secret (§2). `runtime_credentials` gets an
  explicit `connector` branch that gives residents the read endpoint and the
  connection's metadata, **never** the callback secret. (Today every strategy
  other than `refresh_broker` hands over the whole payload.)
- One access profile, `read`, on the connection. Sending is **not** a profile:
  it is a per-resident grant on the access row (§5), so one resident can read
  without being able to send.

Access is one `AgentServiceAccess` row per resident, the same as for Gmail.
Enabling access goes through `resident_access_changeable_by?(enabled: true)`,
the existing granting check, which is not the same as `manageable_by?`. The
read API uses the same scope as `Api::V1::ServiceConnectionTokensController#show`:

```ruby
connection = current_api_agent.service_connections
  .merge(AgentServiceAccess.enabled)
  .find_by_public_id!(params[:service_connection_id])
```

That scope is checked on every request, and the connection must be `connected`.
Disabling or deleting the access row ends reads on the next request.

**Storage.** Messages live in Rails, in two tables keyed to the connection:
`comms_chats` (provider chat ID, name, kind, last activity) and `comms_messages`
(provider message ID, chat, sender ID, sender name, sent_at, body, media kind,
caption). Sender IDs, names, bodies and captions use `encrypts`, like
`credential_payload`. Messages are keyed on `(service_connection_id,
provider_message_id)` and immutable once stored: the first delivery wins, and
edits are not modelled in milestone 1 (as built in #260). Media are not
downloaded in milestone 1: a message records `[image]`, `[voice note]` and so
on, plus the caption.

**Read API and CLI.**
`GET /api/v1/service_connections/:id/comms/chats` and
`GET /api/v1/service_connections/:id/comms/messages?chat=&since=&limit=`, with a
bounded limit and `Cache-Control: no-store`. The resident-side tool is
`soulshouse-comms`, next to `soulshouse-gws`:
`soulshouse-comms --connection svc_x chats` and
`soulshouse-comms --connection svc_x messages --chat X --since T`, both
printing JSON. The catalog entry's `runtime_notes` tell residents it exists.
Scheduled reads are ordinary rhythms. There is no new wake kind.

## 2. The connector

`souls-house-comms` is a Kamal accessory, built like `embeddings`
(`config/deploy.yml`):

- private network only, its own volume `comms:/data`;
- one worker per connection, held by a `flock` on `/data/<ref>/lease`;
- survives web deploys.

It is Go on whatsmeow. It talks only to Rails.

- **Session store.** whatsmeow's `sqlstore` runs on SQLCipher (verified in the
  probe). The key is HKDF(`COMMS_STORE_KEY`, connection ref), where
  `COMMS_STORE_KEY` is an accessory secret like any other, with no second
  ceremony. whatsmeow gets our own `*sql.DB` through `sqlstore.NewWithDB`, and
  the DSN lives only in a closure: `fmt` on a `*sql.DB` prints its DSN (found in
  slice 1).
- **Connector → Rails.** The connector pushes messages, chat updates, status
  changes and the pairing QR to Rails at
  `POST /internal/comms/connections/:id/events` over the private network.
  Each connection has its own callback secret, created with the connection,
  stored in `credential_payload` and given to the connector. Each request is
  HMAC-signed with that secret over the connection ID, method, path, a
  timestamp and the raw body. A request signed for connection A cannot write
  to connection B, a stale timestamp is refused, and a nonce is remembered
  for the freshness window, so a replayed QR or status event is refused too. Rails rejects events for a connection that is not
  `pairing`/`connected`.
- **Rails → connector.** Commands signed the same way with the connection's
  secret: start pairing, unpair (whatsmeow `Logout`, then delete the session
  store), and `send_text` (§5). Disconnecting the `ServiceConnection` sends
  unpair.
- **Pairing QR.** Only the owner's connection page shows it. The connector
  pushes each QR code with its expiry; Rails holds it encrypted in a column
  that is cleared on pairing, on expiry (whatsmeow rotates codes every 20–60
  seconds) or on cancel. It is never logged or kept.

## 3. Credential and log hygiene

These are credential-leak fixes, not privacy architecture.

- libsignal's default logger prints to stdout, which ends up in Docker logs on
  the host. Install a no-op logger.
- Never give whatsmeow a Debug logger: it logs every node, including phone
  numbers.
- `--ulimit core=0` and `GOTRACEBACK=none` on the accessory, because this host's
  `core_pattern` pipes cores to apport on the host.
- The connector logs no bodies, names, JIDs, QR codes or keys. Rails filters
  `body`, `caption`, `name` and `qr` on the internal endpoint.
- One small smoke test before pairing: run synthetic events through, then grep
  the connector's and Rails' logs for the canary.

## 4. History and cutover

The Dell bridge's whatsmeow SQLite and `pa/comms/` are Daniel's history, so we
import them. A fresh pairing receives only recent history. The sequence:

1. Pair a fresh house device. The Dell device keeps running. Two different
   linked devices are fine; two copies of the *same* device are what fights.
2. Import the Dell's history with a one-off import task, deduplicated on
   provider message ID.
3. Check for overlap, then stop `pa-whatsapp-bridge.service`, disable **only
   the WhatsApp branch** of `sync-comms.py` (it also ingests Telegram and Gmail,
   which stay), and unlink the Dell device from Daniel's phone.

The import reads the structured source first, the bridge's whatsmeow message
SQLite with provider IDs. The mixed `pa/comms/` archive may not keep provider
IDs good enough to deduplicate on, so it's used only for what the structured
source lacks, after checking.

Moving the Dell's stopped device into the house would save one linked-device
slot but means copying a live credential. Fresh pairing plus import is simpler.

## 5. Sending

A message sent through this connection goes out **as Daniel**, from his number,
and shows up on his phone and every linked device. Nothing here can make it
private from him, and nothing should: the requirement is that he can always see
which resident said what, to whom, and when.

**The grant.** A new column, `agent_service_accesses.can_send`, boolean,
default `false`.

- Read never implies send. A send needs the access row enabled **and**
  `can_send`. Send implies read, because a resident needs chat IDs to address
  anything; disabling the row ends both on the next request.
- Only the **owner** can turn `can_send` on (`owner?`, not `provisionable_by?`):
  speaking as a person is that person's grant to give. Account admins and
  `freely_provisionable` confer nothing here. Withdrawing it uses
  `manageable_by?`, so an admin can still stop a resident sending.
- `apply_default_accesses` and `follows_default` never set it. A new resident
  or an "enabled for new residents" connection gets read at most.
- Turning `can_send` on is itself recorded (who, when) and shown on the owner's
  connection page.

**The endpoint.** `POST /api/v1/service_connections/:id/comms/messages` with
`chat`, `text` and `client_request_id`. It uses the read scope, then requires
`can_send` on the same access row (403 `send_not_granted` otherwise; the
resident can already see the connection, so 404 would hide nothing).

- Text only, length-bounded. No media, no reactions, no edits or deletes.
- The chat must already exist on this connection (`comms_chats`). Milestone 1
  cannot start a conversation with a number Daniel has never exchanged messages
  with; that is the "no unsolicited" rule made structural.
- One chat per request. There is no list or broadcast form.
- `client_request_id` is unique per (connection, resident). A retry with the
  same ID returns the original send record and does not send again.
- Human pace, enforced per connection and per resident: a small number of
  sends per minute and per day (proposed 6/minute and 100/day per connection,
  for Daniel to adjust), returning 429 beyond it.
- `soulshouse-comms send --chat X --text -` (text on stdin), printing the send
  record. The catalog's `runtime_notes` say plainly that it sends as the
  connection's owner.

**The send record.** A new table, `comms_sends`: connection, resident
(`agent_id`), chat, `text` (`encrypts`), `client_request_id`, status
(`pending`, `sent`, `failed`, `unknown`), provider message ID, error code,
`requested_at`, `sent_at`. The row is written **before** the connector is
called, so a send that happened always has a record. The owner's connection
page lists them: which resident, when, to whom, what, and the outcome. A sent
message also lands in `comms_messages` with `from_me: true` and
`sent_by_agent_id`, so a resident reading a chat sees what another resident
already said in it.

**The connector side.** `send_text` is a signed Rails → connector command
carrying the send record's ID, the chat and the text. The connector calls
whatsmeow `SendMessage` with a message ID derived from the send record's ID and
remembers completed send IDs, so a repeated command is not a second message.
Rails waits with a bounded timeout. A timeout marks the record `unknown`, and
Rails never retries an `unknown` send by itself: a duplicate message to a
person is worse than a missing one. The connector logs no text, chat or JID;
Rails filters `text`.

**Not in milestone 1:** media, new conversations, scheduled sends, sending as
anyone but the owner, and any automatic signature. Whether residents sign their
messages (as Lume does by hand from the Dell bridge today) stays a convention
in the resident's own instructions; Daniel can ask for it to be enforced later.

## 6. WhatsApp's side

Hosting linked devices on a server has precedent: Beeper runs whatsmeow bridges
for many users. That is precedent, not approval. Unofficial clients are against
WhatsApp's terms, a ban is always possible and would land on Daniel's number,
and sending is what attracts bans: bulk, unsolicited, or from fresh numbers.
Human-paced sends from a long-established personal number, into chats he
already has, is what the Dell and Mac bridges already do; §5's rules (existing
chats only, one chat per request, rate limits) keep the house there.
**Before pairing, check the current limits:** linked devices per account
(4 at last check, and this takes one), logout after the phone has been offline
for 14 days, and how much history a new device receives.

## 7. Milestone 1 acceptance

- A resident with an enabled access row reads chats and messages. A resident
  without one gets 404, and so does one with a disabled row.
- Cross-connection and cross-account reads get 404.
- A connector event signed for connection A is rejected for connection B, and
  unsigned or badly signed events are rejected.
- **Send:** a resident with read but not `can_send` gets 403 and no send record
  or connector call. Default accesses never carry `can_send`. A non-owner admin
  cannot grant it, including on a freely provisionable connection, and can
  withdraw it. A chat not on this connection is 404. A repeated
  `client_request_id` sends once. Rate limits return 429. Every send, including
  failed and `unknown` ones, has a record the owner can read, naming the
  resident, chat, time and text, and no other user can read it. No text appears
  in either side's logs.
- The connector restarts and reconnects from its session store with no
  re-pairing.
- A database backup restores the messages (they are ordinary encrypted
  columns). Losing the connector volume costs a re-pair, not history.
- The QR code is visible only to the owner, and is gone after pairing or expiry.
- The log smoke test (§3) passes.

## 8. Build order

1. **Rails:** catalog entry, `comms_chats`/`comms_messages`, the signed internal
   events endpoint, the read API, `soulshouse-comms`, and tests driven by
   synthetic signed events. No Go needed.
2. **Connector with a synthetic provider** posting signed events. From #259
   this keeps the SQLCipher store, the lease and the process hardening. Its
   tickets, read API, access log and KEK envelope are dropped.
3. **whatsmeow**, then pairing on Daniel's real device after the §6 check,
   then the history import and cutover.
4. **Sending:** the Rails grant, `comms_sends`, the endpoint and
   `soulshouse-comms send`, tested against synthetic connector responses (this
   part can be built alongside 2–3); then `send_text` in the connector, first
   to a chat Daniel names as safe for a test.

Telegram (Telethon user session) follows the same shape in its own room.
