# WhatsApp connections: milestone 1 (Daniel's own number)

Status: **proposal, not implemented.** Revision 3, re-scoped after Daniel's
correction in OjyBlJ. Reviewed by Mira in RjpvrY. Deploy remains Daniel's call.

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
- One access profile, `read`. A `send` profile is reserved and not offered in
  milestone 1. There is no send code anywhere.

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
caption). Sender IDs, names, bodies and captions use `encrypts`, like `credential_payload`. Upserts are keyed
on `(service_connection_id, provider_message_id)`, so a replayed event is a
no-op. Media are not downloaded in milestone 1: a message records `[image]`,
`[voice note]` and so on, plus the caption.

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
- **Rails → connector.** Two commands, signed the same way with the
  connection's secret: start pairing, and unpair (whatsmeow
  `Logout`, then delete the session store). Disconnecting the
  `ServiceConnection` sends unpair.
- **Secret bootstrap (open, for slice 2).** The connector has to hold a
  connection's callback secret before it can verify the first start-pair
  command. Options: the connector is given each secret through a
  connector-wide service credential on the first command, or Rails signs
  commands with a separate connector-wide key and hands over the per-connection
  secret inside start-pair. To be settled with the connector, not in Rails.
- **Body bound.** `CommsBodyLimit` (Rack, ahead of Rails) refuses an oversized
  or undeclared-length POST to `/internal/comms/` before any parser, params
  access or logging can read it. The reverse proxy should apply the same bound.
- **Ordering.** A fresh nonce does not order events. QR events carry
  `issued_at`, and an older code never replaces a newer one. Messages are
  immutable once stored: the first delivery of a provider id wins, and edits
  and deletions are not modelled in milestone 1.
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

## 5. WhatsApp's side

Hosting linked devices on a server has precedent: Beeper runs whatsmeow bridges
for many users. That is precedent, not approval. Unofficial clients are against
WhatsApp's terms, a ban is always possible and would land on Daniel's number,
and sending is what attracts bans. Receive-only on a long-established personal
number is the lowest-risk use, and it is what the Dell bridge has been doing for
months. **Before pairing, check the current limits:** linked devices per account
(4 at last check, and this takes one), logout after the phone has been offline
for 14 days, and how much history a new device receives.

## 6. Milestone 1 acceptance

- A resident with an enabled access row reads chats and messages. A resident
  without one gets 404, and so does one with a disabled row.
- Cross-connection and cross-account reads get 404.
- A connector event signed for connection A is rejected for connection B, and
  unsigned or badly signed events are rejected.
- No send endpoint, scope or connector code exists.
- The connector restarts and reconnects from its session store with no
  re-pairing.
- A database backup restores the messages (they are ordinary encrypted
  columns). Losing the connector volume costs a re-pair, not history.
- The QR code is visible only to the owner, and is gone after pairing or expiry.
- The log smoke test (§3) passes.

## 7. Build order

1. **Rails:** catalog entry, `comms_chats`/`comms_messages`, the signed internal
   events endpoint, the read API, `soulshouse-comms`, and tests driven by
   synthetic signed events. No Go needed.
2. **Connector with a synthetic provider** posting signed events. From #259
   this keeps the SQLCipher store, the lease and the process hardening. Its
   tickets, read API, access log and KEK envelope are dropped.
3. **whatsmeow**, then pairing on Daniel's real device after the §5 check,
   then the history import and cutover.

Telegram (Telethon user session) follows the same shape in its own room.
