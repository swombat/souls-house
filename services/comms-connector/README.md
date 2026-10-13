# Comms connector (WhatsApp)

The house's WhatsApp connector: a private-network Kamal accessory
(`souls-house-comms-whatsapp`) holding one whatsmeow linked device per
WhatsApp `ServiceConnection`. Build steps 2 and 3 of
`docs/proposals/2026-10-09-whatsapp-connections.md` (§2, §3, §7).

Receive only. There is no send endpoint, scope or code.

```
cmd/comms-connector/   startup: hardening, env, manager, mTLS command server
internal/command/      verifies Rails's signed commands (COMMS_COMMAND_KEY)
internal/sig/          both signatures, byte for byte with the Ruby (vectors in tests)
internal/server/       manager (start_pairing / unpair / boot) and the HTTP handler
internal/worker/       one connection: lease, store, session, ordered delivery to Rails
internal/rails/        signed POST /internal/comms/connections/:id/events
internal/provider/     Session/Sink seam; deterministic Synthetic provider
internal/whatsapp/     whatsmeow provider (sqlstore.NewWithDB on our *sql.DB)
internal/store/        per-connection SQLCipher store: meta, outbox, carryover, whatsmeow_* tables
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
`POST /connections/<svc_id>/start_pairing` and `/unpair`, over mutual TLS
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
stored, retried only until it expires), and, through the store's outbox,
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
4. **Secrets** in `.kamal/secrets`: `COMMS_STORE_KEY` (`openssl rand -base64 32`)
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
- Group names come from a `GetGroupInfo` call per chat per run; untested
  online.
- Media are never downloaded (milestone 1): a message records the kind and
  caption.
- The Docker image has not been built here (no Docker in this environment).
