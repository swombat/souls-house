# Comms connector (slice 1: synthetic)

One worker per connection, holding message content inside the house's comms
accessory and nowhere else. This is slice 1 of
`docs/proposals/2026-10-09-whatsapp-connections.md` (§2, §3, §6b): the
envelope, the encrypted store, the lease, the hash-chained access log and the
ticketed read API, fed by a **synthetic provider**. There is no whatsmeow and
no network access to WhatsApp. Nothing here is deployed or wired into
`config/deploy.yml`.

```
cmd/comms-connector/   startup: hardening, env, lease, DEK, store, provider, HTTP
internal/keys/         KEK parsing, DEK wrap/unwrap, HKDF subkeys, log IDs
internal/store/        SQLCipher store (chats, messages, access_log), hash chain
internal/lease/        flock on <data>/<ref>/lease
internal/provider/     Provider/Sink interfaces, deterministic Synthetic, Inject
internal/ticket/       ticket verification and the Rails consume call
internal/api/          GET /v1/connections/{ref}/chats and …/messages
internal/harden/       PR_SET_DUMPABLE=0, RLIMIT_CORE=0, umask 077, GOTRACEBACK check
```

Dependencies: stdlib, `golang.org/x/crypto` (XChaCha20-Poly1305), `golang.org/x/sys`
(prctl, rlimit, flock), and `github.com/mattn/go-sqlite3` **replaced by**
`github.com/jgiannuzzi/go-sqlite3 v1.14.35-0.20260227142656-2c447b9a2806`
(SQLite3 Multiple Ciphers 2.2.7, SQLite 3.51.2, used in SQLCipher v4 mode), the
same pin as the slice 0 probe. `go.sum` pins the checksums.

## Build and test

cgo is required, and the build **must** define `SQLITE_TEMP_STORE=3`. The store
refuses to open in a binary built without it (it checks `PRAGMA compile_options`).

```sh
make test      # CGO_ENABLED=1 CGO_CFLAGS="-O2 -g -DSQLITE_TEMP_STORE=3" go test -count=1 ./...
make build     # bin/comms-connector
```

## Running

```sh
COMMS_KEK=<base64 of 32 bytes> \
COMMS_TICKET_SECRET=<at least 32 bytes> \
COMMS_CONSUME_URL=http://souls-house-web:3000 \
comms-connector -listen 0.0.0.0:8080 -data /data \
  -connection <ref> -key-generation <n> [-init] [-provider synthetic]
```

- It refuses to start if `COMMS_KEK` is missing or doesn't decode to exactly 32
  bytes (canonical standard base64 only), if `COMMS_TICKET_SECRET` is missing or
  shorter than 32 bytes, if `COMMS_CONSUME_URL` isn't a plain http(s) URL, or if
  `GOTRACEBACK` is set to anything but `none`.
- `-connection` (or `COMMS_CONNECTION_REF`) must match `[A-Za-z0-9_-]{8,64}`; it
  names the directory `<data>/<ref>/`. `-key-generation` (or
  `COMMS_KEY_GENERATION`) is required and is the only generation the worker serves.
- `-init` creates `dek-<gen>.wrapped` for a new connection and refuses if it
  already exists. Without `-init`, a missing wrapped DEK is fatal.
  The worker never creates keys implicitly.
- `-provider` defaults to `none`. `synthetic` writes deterministic fake chats.
  The only injection path is `provider.Inject`, a Go function used by tests;
  there is no injection endpoint.

On disk, per connection (all files 0600 in a 0700 directory):

```
/data/<ref>/lease               flock target (one worker per connection)
/data/<ref>/dek-<gen>.wrapped   "CDK1" || nonce(24) || XChaCha20-Poly1305(KEK, DEK)
/data/<ref>/store-<gen>.db      SQLCipher v4 (+ -wal, -shm)
```

### Container

The Dockerfile is multi-stage. The build stage runs vet and the tests with
`CGO_CFLAGS=-DSQLITE_TEMP_STORE=3`; the runtime image is distroless and runs as
nonroot. It is meant to run like this (Kamal accessory options to match):

```sh
docker run --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --ulimit core=0 --memory 256m --memory-swap 256m \
  -e GOTRACEBACK=none -e COMMS_KEK -e COMMS_TICKET_SECRET -e COMMS_CONSUME_URL \
  -v comms:/data --network <private> souls-house-comms \
  -listen 0.0.0.0:8080 -connection <ref> -key-generation <n>
```

- **`GOTRACEBACK` must be unset or `none`, never `crash`** (a crash dump would
  carry heap plaintext). The binary refuses other values, and the image sets `none`.
- At startup the binary also sets `prctl(PR_SET_DUMPABLE, 0)` (no core dumps, no
  same-uid ptrace or `/proc/<pid>/mem`) and `RLIMIT_CORE=0`. Keep
  `--ulimit core=0` regardless, because the host `core_pattern` pipes to apport (§6b).
- `--memory-swap` equal to `--memory` disables swap for the container (§2).
- No published port: the API is plain HTTP on the private network only.

## Read API (contract for the Rails side)

`GET /v1/connections/{ref}/chats` returns at most 200 chats, most recently updated
first. `GET /v1/connections/{ref}/messages?chat=<id>&limit=<n>` returns the newest
`n` messages of one chat (`n` from 1 to 200, no leading zeros, both parameters
required, no others allowed). Chat IDs are connector-assigned opaque IDs, never JIDs.

Every response has `Cache-Control: no-store`. Errors are fixed strings
(`bad request`, `not found`, `method not allowed`, `forbidden`, `unavailable`,
`internal error`) and never echo input. Routing is exact: there is no ServeMux,
so no redirect that would echo the path, and escaped paths are refused.

**Ticket** (`X-Comms-Ticket`, exactly one):

```
header  = b64url(payload) "." b64url(HMAC-SHA256(COMMS_TICKET_SECRET, "comms-ticket-v1." || b64url(payload)))
payload = {"ticket_id","connection_ref","key_generation","access_epoch","grant_id",
           "principal","api_key_id","run_id","expires_at","request_digest"}   (no other fields)
request_digest = hex(SHA-256(METHOD "\n" PATH "\n" CANONICAL_QUERY))
```

`b64url` is RFC 4648 §5 without padding, and only the canonical encoding is
accepted. `expires_at` is unix seconds, in the future and at most 60 s ahead.
`PATH` is the escaped request path. `CANONICAL_QUERY` is the query sorted by key
and encoded as Go's `url.Values.Encode` (`chat=chat-0001&limit=5`), or empty;
repeated keys are refused. `ticket_id` matches `[A-Za-z0-9_-]{8,128}`. Grant,
principal, API key and run IDs match `[A-Za-z0-9_.:/-]{1,128}`.

The connector verifies the shape, the signature (constant time), the fields, the
expiry, `connection_ref` (equal to the served ref), `key_generation` (equal to
the served generation) and the digest, in that order. Only then does it
**consume**:

```
POST $COMMS_CONSUME_URL/internal/comms/tickets/<ticket_id>/consume
Content-Type: application/json
X-Comms-Signature: b64url(HMAC-SHA256(secret, "comms-consume-v1\n" || ticket_id || "\n" || body))
body: {"ticket":"<the X-Comms-Ticket value>"}
```

The read proceeds only on HTTP 200 with `Content-Type: application/json` and a
body that is exactly `{"allowed": true}`: no other fields, nothing after it, at
most 1 KiB. Everything else counts as a refusal (403 to the caller): any other
status, a redirect (never followed), a malformed body, or `allowed:false`. A
timeout (3 s) or a connection error returns 503. The client ignores
`HTTP(S)_PROXY`.

After an allow, the worker reads the rows, builds the response in memory,
appends the access-log entry in one committed transaction
(`synchronous=FULL`), and only then writes the response. If the append fails,
the caller gets 500 and no rows.

## Access log

The `access_log` table lives in the same encrypted store. Each entry has:
`seq, prev_hash, hash, principal, api_key_id, run_id, ticket_id (UNIQUE),
grant_id, access_epoch, key_generation, scope, row_count, at_unix_ms`. Scope is
`chats:max=200` or `messages:chat=<opaque id>:limit=<n>`. Entries never hold
content.

```
hash = SHA-256(prev_hash || enc(entry)),  prev_hash(seq 1) = 32 zero bytes
enc  = lp("comms-access-log-v1") || be64(seq) || lp(principal) || lp(api_key_id)
    || lp(run_id) || lp(ticket_id) || lp(grant_id) || be64(access_epoch)
    || be64(key_generation) || lp(scope) || be64(row_count) || be64(at_unix_ms)
lp(x) = be32(len(x)) || x
```

`store.VerifyChain` reports the first broken link. As §3 says, the chain has no
independent anchor, so someone holding the store key can rewrite all of it.

## Keys

- DEK: 32 random bytes per (ref, generation), wrapped with XChaCha20-Poly1305
  under the KEK. Each wrap uses a fresh 24-byte nonce, and the AAD is
  `lp("comms-dek-v1") || lp(ref) || lp(be64(gen))`, so a wrapped DEK doesn't
  open for another ref or generation.
- SQLCipher key: `HKDF-SHA256(DEK, salt=∅, info="comms-sqlcipher-v1")`, 32
  bytes, passed as a raw key (`x'…'`) **in the DSN**
  (`_cipher=sqlcipher&_legacy=4&_key=…`), never through a ConnectHook (§6b).
- The ConnectHook runs on every pooled connection: `foreign_keys=ON`,
  `journal_mode=WAL`, `temp_store=MEMORY`, `secure_delete=ON`,
  `synchronous=FULL`, `busy_timeout=5000`. `Open` verifies all of them.
- Log IDs: `hex(HMAC-SHA256(HKDF(KEK, "comms-log-id-v1"), ref))[:16]`.

## Logs

`log/slog` JSON goes to stderr. The fields are `time, level, msg, conn` (the keyed
log ID), `status, reason` (a fixed code), `rows, dur_ms`, and `key_generation` at
startup. The worker never logs bodies, names, chat IDs, JIDs, principals,
tickets, the DSN, keys or error strings. The http.Server's own error log is
discarded. Handler panics are recovered without logging the panic value.

## Known limits of slice 1

- The DSN (with the raw SQLCipher key) and the key bytes live in Go memory and
  cannot be reliably zeroed. Non-dumpable, no swap and no core dumps are the
  mitigations.
- Key rotation (a new generation and a rekey) is not implemented. The worker
  serves exactly the generation it was started with.
- The Docker image has not been built in this slice (no Docker on the build host).
  The real-image checks (`docker diff`, `docker logs`, a forced crash) belong to slice 4.
