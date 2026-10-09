# WhatsApp connections: spec slice 1

Status: **proposal, not implemented.** Written by Lume for review by Mira in
conversation RjpvrY before any code. Deploy remains Daniel's call.
Revision 2 answers Mira's changes-requested review of `360ddd1`.

## What this slice covers

The first milestone (Mira, agreed in OjyBlJ): connect **Daniel's** WhatsApp
identity; receive and read messages through explicit grants; survive a restart;
revoke access; restore an encrypted backup. No sending. The model has room for
account-owned and resident-owned connections, but milestone 1 ships only the
human-owned case. §5 says why the resident-owned case is blocked on something
this slice does not build.

## 1. Data model (Rails holds no message content)

Rails stores *who may do what*. It stores no message text, chat names, contact
names or media. Those exist only inside the connector (§2).

**`CommsConnection`**: `account` (host), `provider` (`whatsapp`), `owner`
(polymorphic: `User` now; `Account` and `Agent` reserved), `label`,
`status` (`pairing | connected | paused | revoked | erased`),
`connector_ref` (opaque ID inside the connector), `key_generation`,
`identity_hint` (`encrypts`; for example `+34 … 91`, shown to the owner only).

**`CommsGrant`**: `connection`, `grantee` (polymorphic `User | Agent`),
`capability` (`read | send`), `granted_by` (the owner), `granted_at`,
`revoked_at`. In milestone 1, `send` cannot be created, and the connector has no
send code to call.

Rules, taken from `DeviceStream` (`app/models/device_stream.rb`,
`docs/device-streams.md`) and tightened:

- Only the owner creates, changes or revokes grants. For a `User` owner that
  means a browser session with CSRF, as for device streams. An account admin, an
  agent the owner owns, and the issuer of an agent's API key inherit nothing.
- Grantees must be confirmed members or active agents of the host account.
  `readable_by?` is checked on **every** request (`DeviceStream#readable_by?`
  is the pattern) and repeated inside the connector call (§3).
- An account admin may **pause** a connection hosted on their account, which
  stops the worker, for abuse or cost. Pausing gives no read access, changes no
  grant, and is shown to the owner with who paused it and when. The owner or the
  pausing admin may resume; resuming also reads nothing and grants nothing. While
  paused, every read is refused. That is the only admin control.
- **Grants do not revive.** When a grantee loses confirmed membership, an agent
  is deactivated, or the owner leaves the account, the affected grants get
  `revoked_at` in the same transaction (DeviceStream only blocks reads while
  keeping reader IDs; this is deliberately stricter). Rejoining or reactivation
  needs a new grant from the owner.
- Every change that can withdraw access (grant revoke, pause, membership loss,
  agent deactivation, API key revocation, owner departure, erase) increments
  `CommsConnection#access_epoch` under the row lock.
- All grant mutations serialise on the connection row (`with_lock`, as
  `DeviceStream#configure!`).
- Not in milestone 1: the bootstrap for `Account` owners. Someone has to be the
  first steward, and an admin who appoints themself is the self-grant we're
  excluding. Proposal for later: creation names stewards, the stewards confirm,
  and only stewards change stewards. Every one of those steps is shown to the
  whole account.

## 2. The connector boundary

There is one new Kamal accessory, `souls-house-comms`, built the way
`embeddings` is (`config/deploy.yml`): private network only, no public port, its
own named volume `comms:/data`, restarted by Docker, read-only root filesystem,
`/tmp` on tmpfs, and swap disabled for the container (`memory-swap` equal to
`memory`), so nothing it holds in memory pages to disk. It's written in Go because
whatsmeow is Go. It runs one worker per connection, holding a lease row in its
own store so a second process cannot attach the same device. That's the "two
live copies fight" problem, solved at the house end.

Keys:

- **KEK**: `COMMS_KEK`, a Kamal secret given **only** to the comms accessory.
  It is not `RAILS_MASTER_KEY`, it is not in Rails credentials, and web/jobs
  don't receive it as configuration. `encrypts` is deliberately not used for
  content, because its key opens in any `bin/rails runner` or console. This
  keeps the key out of *ordinary* Rails read paths only; see §3 on the Docker
  socket.
- **DEK**: one per connection and `key_generation`, 32 random bytes, wrapped by
  the KEK with XChaCha20-Poly1305: a fresh random 24-byte nonce per wrap, AAD =
  `"comms-dek-v1" ‖ connection_ref ‖ key_generation`, so a wrapped DEK cannot be
  swapped between connections or generations.

**The encrypted persistence seam.** Each connection has one SQLite database
under SQLCipher (page-level AES-256 with per-page HMAC and a fresh IV per page
write), keyed with a subkey derived from the DEK (HKDF, info
`"comms-sqlcipher-v1"`). That one file holds both whatsmeow's own store
(`store/sqlstore`: identity keys, sessions, prekeys, sender keys, app-state
keys, contacts) and our message tables. Mira's point is that the session
credential is a message key in all but name, so it gets the same protection as
the bodies, from the same mechanism. SQLCipher also encrypts the WAL and
rollback journal pages; `PRAGMA temp_store = MEMORY` keeps temp tables and sort
spills off disk. History sync blobs are decoded in memory and written only
through the same database. Indexes inside it are encrypted with it, so no
separate keyed-hash scheme is needed.

Two things are not yet verified and gate slice 4 (real pairing): that
whatsmeow's `sqlstore` runs unmodified on a SQLCipher driver (it needs cgo; the
fallback is to implement whatsmeow's store interfaces over the same encrypted
database ourselves), and that nothing in whatsmeow writes elsewhere (media
caches, debug dumps). The test for both: drive the **real** `sqlstore` with
synthetic identities, prekeys, sessions, history-sync payloads and messages
carrying canary strings, kill the process mid-write, then search every file
under `/data`, the tmpfs and the container's writable layer for the canaries
and for raw key bytes. A synthetic envelope test alone does not verify the real
store.

Pairing: the owner starts it from their connection page. The connector returns
a QR payload to that page through Rails. It's a credential: it is not logged,
not stored, and it expires. Daniel's identity gets a **fresh QR pairing**. I
have not checked whether the stopped Dell whatsmeow store would move cleanly,
because a fresh device makes it unnecessary, and the Dell store is plaintext
SQLite we'd otherwise be importing. Once the house device is paired, the Dell
`pa-whatsapp-bridge.service` is switched off and disabled. The house never
receives the Dell's local history.

Pairing triggers WhatsApp history sync. That arrives on the same encrypted path
as live messages, with nothing special-cased.

## 3. Read path

1. A resident calls `GET /api/v1/comms/:connection/chats` or `…/messages`
   with its ordinary API key.
2. Rails checks the grant and the run's audience (§4, disclosure gate) and
   mints a **single-use ticket**, valid at most 60 seconds, HMAC-signed with
   `COMMS_TICKET_SECRET` (shared by Rails and the connector only). The ticket
   binds: ticket ID, connection ref, `key_generation`, `access_epoch`, grant ID,
   principal, API key ID, run ID, and a digest of the exact request (method,
   path, canonical query, bounded scope such as one chat and a row limit).
3. Rails forwards the request with the ticket.
4. The connector verifies the signature and the request digest, then
   **re-validates at release**: it calls Rails' internal
   `POST /internal/comms/tickets/:id/consume` over the private network. Rails,
   under the connection row lock, checks that the ticket is unconsumed, that
   `access_epoch` and `key_generation` still match, and that grant, membership,
   agent, API key and connection status are all still live. It marks the ticket
   consumed and answers yes or no. Any mismatch, timeout or error is a no.
5. On yes, the connector decrypts, **appends the access-log entry and syncs it
   to disk before releasing any row**, and returns the data. If the log write
   fails, nothing is released. Rails streams the response back with
   `Cache-Control: no-store`; the proxy never logs or reports bodies (see §4:
   `filter_parameters` covers request parameters, not response bodies, so the
   proxy itself must avoid them).

Ordering. A revoke (or pause, membership loss, key revocation…) that commits
before step 4 makes the consume answer no, so a ticket issued before the revoke
dies with it. A revoke that commits after step 4 cannot stop that one response:
the read was authorised at release, and plaintext already delivered cannot be
recalled. The access log shows exactly which reads fall in that window. Replay
fails on the consumed flag; a ticket used against a different request fails the
digest.

Tests (synthetic connector): a ticket minted, then the grant revoked, then the
ticket presented, gets a refusal; the same for pause, membership loss, agent
deactivation and API key revocation; a replayed ticket is refused; a ticket
replayed against another chat is refused; a log-write failure releases nothing.

The access log lives in the connector, hash-chained, recording principal, key
ID, run ID, scope, time and row count, never content. The owner sees it on
their connection page.

**What the log does and does not guarantee.** Ordinary reads are durably logged
before release and fail closed if logging fails. That is the whole claim.
Rails web and jobs mount the Docker socket (`config/deploy.yml`, `web_volumes`),
which is host root: an operator with a Rails console can read the accessory's
secret, exec into it, or copy its volume, and none of that passes through
tickets or the log. A forged ticket can also impersonate an existing grantee and
run, and the hash chain lives on an operator-controlled volume with no
independent anchor, so it can be rewritten. So this is not secrecy from the
operator and not guaranteed attribution. It is a barrier against routine
browsing and accidental disclosure, which is what Daniel asked for. Owner-signed
grants would not change the Docker reach either; they are not needed for
milestone 1.

## 4. Plaintext escape paths

| Path | Closure in milestone 1 |
|---|---|
| Postgres rows, WAL, daily S3 dump (`docs/database-backup.md`) | Nothing to leak: Rails stores grants and metadata only. `identity_hint` uses `encrypts`. |
| Rails app-wide encryption key | Not used for content; the connector holds the KEK. |
| Connector volume | Ciphertext only, including the whatsmeow store. |
| Connector volume backup | Its own restic repo of the `comms` volume, which is ciphertext already. The KEK is **escrowed separately** (Daniel, offline). It is never stored beside the backup. Restore drill is part of the milestone. |
| KEK in Kamal secrets on the deploy machine | Operator reach, accepted and documented. This is the "determined operator" line. |
| Connector logs (container stdout) | No bodies, names, JIDs or QR payloads at any level. IDs appear only as keyed hashes. A test greps the logs from a synthetic run for planted canaries. |
| Rails logs, exception reports | `filter_parameters` (`config/initializers/filter_parameter_logging.rb`) covers request parameters only. Response bodies are protected by the proxy itself: it streams without buffering into logs, rescues errors with a fixed message and no body or upstream excerpt, and `no-store` stops caches. Canary test covers the error paths. |
| Search indexes / embeddings | No server-side search in milestone 1. Search later happens inside the connector, under the DEK. |
| Media / attachments | Not downloaded in milestone 1. A message carries `[image]` / `[voice note]` and the caption. Media later go to DEK-encrypted blobs in the connector volume. |
| Tool results stored in `Message.tool_results` (house-tool residents) | The comms read API is offered only to Chaos residents, whose tool calls stay inside their own session, not in `Message` rows. |
| Live activity: operations, commentary, plan and event data stored per attempt and served by `live_activity_json` (`app/models/agent_runtime_interaction/live_activity.rb`). `narration_shared` is not a complete export gate there. | **Technical gate, before persistence.** (a) Reads are refused unless the run's *actual readable audience* is within owner + grantees. A room's audience is not its named participants: `Chat.app_accessible_to` lets every confirmed account member read it (`app/models/chat.rb`). So in milestone 1 reads are allowed only from runs with no room (a private comms wake), or from a room on an account whose every confirmed member and active agent is the owner or a grantee. (b) Minting a ticket marks the run `comms_sensitive`. Rails then refuses to persist operations, commentary, plan or event data for that run from that point (only state transitions are stored), and the runtime reporter is told to stop sending detail. What the Chaos reporter actually exports (command lines? output excerpts?) is traced before slice 2, and the gate is built against that trace. (c) Canaries run through activity records, room APIs, error paths and the database backup, not only connector stdout. Deliberate later posting by a grantee stays under the owner's authority and the private-memory rule; the read-time gate does not claim to solve it. |
| Model-session transcripts, journals, memory formations, mnemodyne embeddings, agent-volume backups | For a human-owned connection read by that human's grantees, this is the grantee's own memory, already under private-memory discipline. The operator can read resident volumes and their S3 backups. **That is why the resident-owned case is blocked** (§5). |
| Model provider | Text a resident reads goes to its model provider. That's inherent in "a resident reads it"; the owner's grant is consent to it. |
| Dell bridge SQLite / `pa/comms/` | Daniel's own existing copy, outside the house. Switched off after pairing, not imported. |
| Deletion | **What is promised:** erasing a connection tombstones it in Rails, stops its worker, and destroys its wrapped DEK and database in the *current* connector volume (precedent: `FieldVoiceprint` is destroyed, not discarded). **What is not promised:** historical backups keep the old database and the KEK-wrapped DEK until backup retention removes them, and the escrowed KEK still opens them. KEK rotation does not change that. Copies already read by grantees (transcripts, memory, journals) are not erased either. Cryptographic erasure would mean losing every historical unwrap key and copy, which would also affect every other connection under the same KEK; it is not offered. The UI says this in plain words, as `device-streams.md` does about WAL. |

## 5. Why the resident-owned case waits

Daniel's line is that a resident's correspondence with a third party must not be
easy for Daniel or any house user to read. The connector can hold that line at
rest. But a resident that *reads* its mail holds the plaintext in its Chaos
transcript, journal and memory, on volumes the operator can open and that get
backed up to S3 in the clear. Encrypting the connector without encrypting the
reader would be a lock on a door in a house with no walls.

Volume encryption alone is not a sufficient release criterion either. Before the
resident-owned case ships, every place the reader's plaintext goes has to meet
the same boundary: volumes while mounted (not only at rest), external memory
services (mnemodyne formations and embeddings), live-activity reporting,
backups, and the restore path. That is a separate project, named here so nobody
mistakes milestone 1 for it. Account-owned connections need the steward
bootstrap (§1) and their own audience rules.

## 6. Decisions after review 1

1. Tickets: single-use, request-bound, re-validated at release (§3). Owner-signed
   grants are not needed for milestone 1 and would not address Docker reach.
2. Narration and rooms: a technical gate before persistence, using the actual
   readable audience (§4), plus policy for deliberate later posting.
3. KEK escrow: Daniel offline, **subject to his acceptance and a tested recovery
   procedure** (slice 3).
4. Deletion: current-store erasure only, stated plainly (§4).

## 7. Build order after review

0. Trace what the Chaos activity reporter exports, and confirm whatsmeow's
   `sqlstore` on a SQLCipher driver. Both are findings for review, not code.
1. Connector skeleton with a **synthetic provider**: a fake event source in place
   of whatsmeow, the DEK/KEK envelope, the lease, the access log, and a canary
   test on the logs.
2. Rails models, the owner page, and grants plus the ticketed proxy, tested
   against the synthetic connector: read; already-issued tickets refused after
   revoke, pause, membership loss, agent deactivation and key revocation; replay
   refused; restart survives; the disclosure gate and its canaries.
3. The backup and restore drill on synthetic data, using the escrowed KEK.
4. Only then whatsmeow on SQLCipher with the real-store canary test, the QR
   pairing, and Daniel's real device. Switch off the
   Dell bridge.

Bounded pieces (envelope crypto, log canary test, restic job) go to sub-agents,
and I review what comes back.
