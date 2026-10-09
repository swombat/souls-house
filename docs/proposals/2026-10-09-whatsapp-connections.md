# WhatsApp connections: spec slice 1

Status: **proposal, not implemented.** Written by Lume for review by Mira in
conversation RjpvrY before any code. Deploy remains Daniel's call.

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
  stops the worker, for abuse or cost. Pausing gives no read access and creates
  no grant. That is the only admin control.
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
own named volume `comms:/data`, restarted by Docker. It's written in Go because
whatsmeow is Go. It runs one worker per connection, holding a lease row in its
own store so a second process cannot attach the same device. That's the "two
live copies fight" problem, solved at the house end.

Keys:

- **KEK**: `COMMS_KEK`, a Kamal secret given **only** to the comms accessory.
  It is not `RAILS_MASTER_KEY`, it is not in Rails credentials, and web/jobs
  don't receive it. `encrypts` is deliberately not used for content, because its
  key opens in any `bin/rails runner` or console.
- **DEK**: one per connection (and per `key_generation`), random, wrapped by
  the KEK, stored in the connector volume.
- Encrypted under the DEK (XChaCha20-Poly1305, AAD = connection ref and row ID):
  message bodies, chat and contact names, **and the whatsmeow device/session
  store**. Mira's point is that the session credential is a message key in all
  but name: anyone with it can sign in and read new mail. Indexes hold only
  keyed hashes (HMAC under a DEK-derived key) of JIDs and message IDs.

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
2. Rails checks the grant and mints a **60-second ticket** (HMAC with
   `COMMS_TICKET_SECRET`, shared by Rails and the connector only). The ticket
   names the connection, the principal, the API key ID, the runtime run ID if
   there is one, and the scope.
3. Rails forwards the request with the ticket. The connector verifies it,
   decrypts, **appends an access-log entry**, and returns the data. Rails streams
   it back with `Cache-Control: no-store` and no body logging.

The access log lives in the connector, hash-chained, under the DEK. It records
the principal, key ID, run ID, scope, time and row count, never content. The
owner sees it on their connection page.

**The honest limit.** Rails mints the tickets, so an operator with a Rails
console can mint one. What they cannot do is mint one without it being logged:
the log entry names a grantee and a run ID, and the owner can see a read that
corresponds to nothing that grantee did. That is the "breach that is obviously
a breach" Daniel asked for. It is not cryptographic secrecy from the operator,
and nothing here pretends to be. The stronger version would have the owner sign
grants with a key that never touches Rails. It belongs to the resident-owned
case (§5), not milestone 1.

## 4. Plaintext escape paths

| Path | Closure in milestone 1 |
|---|---|
| Postgres rows, WAL, daily S3 dump (`docs/database-backup.md`) | Nothing to leak: Rails stores grants and metadata only. `identity_hint` uses `encrypts`. |
| Rails app-wide encryption key | Not used for content; the connector holds the KEK. |
| Connector volume | Ciphertext only, including the whatsmeow store. |
| Connector volume backup | Its own restic repo of the `comms` volume, which is ciphertext already. The KEK is **escrowed separately** (Daniel, offline). It is never stored beside the backup. Restore drill is part of the milestone. |
| KEK in Kamal secrets on the deploy machine | Operator reach, accepted and documented. This is the "determined operator" line. |
| Connector logs (container stdout) | No bodies, names, JIDs or QR payloads at any level. IDs appear only as keyed hashes. A test greps the logs from a synthetic run for planted canaries. |
| Rails logs, exception reports | `filter_parameters` for the comms routes (`config/initializers/filter_parameter_logging.rb`), no-store, and the proxy rescues errors without including the response body. |
| Search indexes / embeddings | No server-side search in milestone 1. Search later happens inside the connector, under the DEK. |
| Media / attachments | Not downloaded in milestone 1. A message carries `[image]` / `[voice note]` and the caption. Media later go to DEK-encrypted blobs in the connector volume. |
| Tool results stored in `Message.tool_results` (house-tool residents) | The comms read API is offered only to Chaos residents, whose tool calls stay inside their own session, not in `Message` rows. |
| Working narration shared into a room (`narration_shared`, `app/models/agent_runtime_interaction/live_activity.rb`) | **Policy, not a technical close:** a resident reading a connection follows the private-memory rule and does not narrate or post its content in rooms with people who aren't the owner or grantees. Flagged for review (§6). |
| Model-session transcripts, journals, memory formations, mnemodyne embeddings, agent-volume backups | For a human-owned connection read by that human's grantees, this is the grantee's own memory, already under private-memory discipline. The operator can read resident volumes and their S3 backups. **That is why the resident-owned case is blocked** (§5). |
| Model provider | Text a resident reads goes to its model provider. That's inherent in "a resident reads it"; the owner's grant is consent to it. |
| Dell bridge SQLite / `pa/comms/` | Daniel's own existing copy, outside the house. Switched off after pairing, not imported. |
| Deletion | The house rule is "deletion marks". Erasing a connection tombstones it in Rails **and destroys the DEK** in the connector (precedent: `FieldVoiceprint` is destroyed, not discarded). Older backups keep the KEK-wrapped DEK, so a real erase also needs KEK rotation. The UI says so, as `device-streams.md` does about WAL. |

## 5. Why the resident-owned case waits

Daniel's line is that a resident's correspondence with a third party must not be
easy for Daniel or any house user to read. The connector can hold that line at
rest. But a resident that *reads* its mail holds the plaintext in its Chaos
transcript, journal and memory, on volumes the operator can open and that get
backed up to S3 in the clear. Encrypting the connector without encrypting the
reader would be a lock on a door in a house with no walls. The resident-owned
case therefore needs resident-volume encryption, with keys outside the operator's
routine path, before it ships. That is a separate project, named here so that
nobody mistakes milestone 1 for it. Account-owned connections need the steward
bootstrap (§1) and their own audience rules.

## 6. Questions for review

1. Are Rails-minted tickets plus an owner-visible access log enough for
   milestone 1, or should owner-signed grants come first?
2. Narration and room posting: policy (as written), or a technical gate where
   the read API refuses unless the run's room contains only the owner and
   grantees?
3. KEK escrow: Daniel offline is the proposal. Is there a better custodian?
4. Is anything missing from the escape-path table?

## 7. Build order after review

1. Connector skeleton with a **synthetic provider**: a fake event source in place
   of whatsmeow, the DEK/KEK envelope, the lease, the access log, and a canary
   test on the logs.
2. Rails models, the owner page, and grants plus the ticketed proxy, tested
   against the synthetic connector: read, revoke → 403, pause, restart survives.
3. The backup and restore drill on synthetic data, using the escrowed KEK.
4. Only then whatsmeow, the QR pairing, and Daniel's real device. Switch off the
   Dell bridge.

Bounded pieces (envelope crypto, log canary test, restic job) go to sub-agents,
and I review what comes back.
