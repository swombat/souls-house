# Cloud resident hosting: foundation

Scope: [issue #140](https://github.com/swombat/souls-house/issues/140).
The intended first topology is one Hetzner Cloud VM per resident, not a
dedicated physical server per resident. Pooling is deferred.

## Present boundary

`AgentPlacement` records a resident's backend (`local` or `hetzner_cloud`),
state, provider server ID, future runtime endpoint and generation. The database
allows one placement per resident and one resident per non-null provider server
ID. The owning account is the resident's account; this introduces no new
cross-account interface.

- **No record:** today's local runtime, unchanged. There is no backfill.
- **Local, ready:** today's local runtime, explicitly recorded.
- **Any other placement:** unavailable to today's runtime. No fallback to local
  Docker or the old `Agent#endpoint_url`, even if the remote record says ready.
- Nothing creates placements automatically or offers them in the UI.
- No credentials belong in these records. The HTTPS endpoint is reserved
  metadata, not yet an authorized network destination.

`Agents::RuntimeLocation` reads the current persisted placement rather than a
potentially cached missing association. `Agents::Resources` applies that guard
before local Docker ownership checks, including the legacy production namespace.
Provisioning/startup, endpoint resolution and backup environment construction
also refuse unsupported placement.

Queued turns recheck placement at admission and immediately before submission:
their stored endpoint is not continuing permission to start work. Already
admitted turns use the existing cancellation-tombstone path on refusal, retaining
capacity until the old runtime confirms cancellation. Polling and containment of
already accepted work remain possible at its original endpoint.

This is **not fencing or a movement protocol**. A lookup and subsequent I/O are
not atomic; existing operations may already be in flight. `generation` is only
reserved metadata and is not yet enforced by any runner. Do not change a live
resident's placement to move it. Do not delete a remote placement to “retry”:
absence deliberately means legacy local. `retired` preserves an explicit
unavailable record.

## Integration still needed

1. Explicit hosting entitlement and approved server/image/location allowlists.
2. Durable procurement operations: reconcile unknown create outcomes before
   retrying; record ownership and provider action completion.
3. Bootstrap and a narrowly authenticated runner. Separate administrative
   authority from the resident's environment; no resident Docker socket or
   Hetzner project token.
4. Remote runtime endpoint enrollment and dispatch/lifecycle integration.
   HTTPS syntax validation is not host identity verification or an SSRF policy.
5. Remote backups, verified restore, private provider-state exclusions and a
   real single-writer cutover/fencing protocol.
6. A disposable, bounded-spend live pilot with separately approved credentials.

House-funded inference already has its own gateway and grant ledger; see
[house-funded inference](house-funded-inference.md). Its token entitlement does
not grant a VM or collect a paid hosting subscription.

## Testing and rollback

Use synthetic placement rows and mocked I/O, in the isolated Rails test
environment. Test missing/explicit-local compatibility, remote/non-ready refusal,
fresh lookup after a cached absence, unique database constraints and endpoint
validation. No Hetzner key or running VM is needed.

The migration is additive and creates no records. Existing residents require no
restart. This code is not a production rollout or approval to buy capacity.
Once real remote placements exist, reverting to code that ignores placements
would be unsafe; rollback must preserve the refusal boundary. The foundation
creates no such production placements.

## Host runner enrollment (pilot telemetry, #192)

A VM ordered for the pilot runs a small host runner
(`host-runner/souls_house_runner.py`) that **dials out** to Rails. This is a
deliberate, bounded deviation from the architecture page, which has Rails
calling the runner over a private network. It covers enrollment and telemetry
only; the transport for resident turns is still undecided.

- **Boot.** Procurement renders cloud-init with `RunnerUserData.render` and
  sends it in its single create request. The document installs Docker,
  `python3-cryptography` and nftables, embeds the runner source, and writes a
  0600 config holding the one-time enrollment token. That token is the only
  secret in it.
- **Token.** `RunnerEnrollment.mint!` is called inside procurement's create
  intent transaction. It stores only the SHA-256 digest and a 24-hour expiry.
  There is no re-mint. A lost plaintext or an expired token means operator
  review.
- **Enrollment.** `POST /api/v1/host_runner/enrollment` is signed with the
  key it asks Rails to pin, which proves possession. Until procurement calls
  `confirm_provider_server!`, the answer is 202 and the token is not burned.
  After that, the reported Hetzner server ID must match. A repeated request
  with the same key is answered "already enrolled", which is how a lost reply
  recovers. A different key is refused.
- **Signing.** Ed25519 over `souls-house-runner-v1`, method, path, the body's
  SHA-256, the runner ID, the timestamp and a nonce. The runner uses Debian's
  `python3-cryptography` and Rails uses Ruby's OpenSSL. No crypto is
  hand-written. Rails allows ±120 s of skew, caps bodies at 64 KB and rejects
  reused nonces through a unique index.
  `test/fixtures/files/runner_signature_vector.json` is produced by the Python
  runner and verified by Rails, which pins the format in both languages.
- **Heartbeats.** `POST /api/v1/host_runner/heartbeat` is signed with the
  pinned key and stores a fixed list of host facts. Health is derived from
  heartbeat age and lapses on its own.
- **What it cannot do.** The runner knows two actions, `report_facts` and
  `heartbeat`, and refuses anything else locally. Rails has no command queue.
  Enrollment and health never make a placement ready or permit dispatch.
- **Network.** Host input is dropped except loopback, established traffic,
  ICMP and SSH. SSH exists for Daniel's offline break-glass key; Rails holds
  only the public half or its Hetzner key ID. Rails stays root-equivalent over
  the VM through the Hetzner project token (rebuild, rescue, user_data at
  create). The firewall limits the network, not Rails.

`RunnerEnrollment` is separate from procurement's states. Provisioned is not
enrolled, enrolled is not healthy, and healthy is not runtime-ready.
