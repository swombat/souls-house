# Review: Agent service integrations

**Reviewed:** `260728-01-agent-service-integrations.md`
**Date:** 2026-07-28
**Verdict:** Keep the Rails-owned gateway and lazy agent-facing documentation, but revise the connection, ownership, permission, and lifecycle model before implementation.

## The central correction

The draft models a service connection as:

> one service credential belonging to a HelixKit account

The product examples require:

> a named external identity, connected by a person, which may expose one or more capabilities to selected agents

Those are not the same object.

`t.index [:account_id, :service], unique: true` permits only one Gmail, Dropbox,
or Oura identity in an account. It cannot represent Daniel's personal Gmail and a
work Gmail, two Dropbox accounts, or two team members' Oura rings. It also gives
an account admin apparent ownership of credentials and consent that may actually
belong to an individual user.

The durable center should therefore be:

- an **external connection**: a particular authorized external identity or
  credential pool, with a stable id and human-readable label;
- one or more **capabilities** exposed by that connection;
- explicit **agent grants** over actions on a particular connection;
- provider-specific consumers which may be live actions, scheduled sync,
  webhooks, context projection, or some combination.

The proposed generic invocation API is a useful consumer of this framework. It
should not define the whole integration framework.

## What is already right

1. **Rails should own user-data credentials.** OAuth access and refresh tokens
   should not enter agent containers. Central refresh, revocation, audit, and
   immediate grant removal are the right boundary.
2. **Agent discovery should be live and pull-based.** A small manifest, an
   on-demand manual, and a generic helper fit Chaos better than eagerly loading
   every service schema into model context.
3. **Grants should be Rails-side records.** Service access should not be written
   into agent identity files or require container recreation.
4. **Adapters should declare their agent-facing contract.** Deriving validation,
   manifests, manuals, and routing from one action declaration is a good way to
   prevent drift.
5. **External content must be treated as untrusted.** The prompt-injection
   warning is necessary, though not sufficient by itself.

## Findings

### 1. [High] The cardinality excludes multiple external accounts

Lines 50-62 make `(account_id, service)` unique, while the manifest and invoke
route identify only the service. This makes all of these impossible:

- personal Gmail plus work Gmail;
- two users sharing different mailboxes with the same team agent;
- personal and company Dropbox;
- multiple Oura users in a team account;
- reconnecting a provider under a second identity without replacing the first.

Every connection needs:

- a stable public `connection_id`;
- a user-chosen `label`;
- provider-reported identity fields such as `external_subject_id`,
  `external_email`, or display name;
- uniqueness based on the external identity where the provider supplies one,
  not uniqueness of the service itself.

The manifest should identify both capability and connection:

```json
{
  "connection_id": "svc_7k...",
  "service": "gmail",
  "label": "Daniel — work",
  "identity": "daniel@example.com",
  "actions": ["search_messages", "read_message"]
}
```

Invocation must include that `connection_id`; otherwise an agent cannot say
which mailbox or Dropbox it intends to use.

### 2. [High] Account containment is being confused with credential ownership

The existing code already demonstrates both ownership shapes:

- `OuraIntegration` belongs to a `User`;
- `GithubIntegration` and `XIntegration` belong to an `Account`.

The draft collapses all future integrations to `account_id` and gates management
through account admins. In a team account, that could let an admin broaden agent
access to a mailbox or health record authorized by another member.

An external connection should record at least:

- `account_id`: where the connection may be used;
- `connected_by_user_id`: who completed the consent flow;
- whether the connection is **personal/delegated** or **account-managed**;
- who may broaden scopes, reconnect it, grant it, and disconnect it.

Recommended policy:

- the consenting user controls scope expansion and delegation for a personal
  connection;
- account admins may disable a grant or remove a connection from the account,
  but may not silently broaden another user's consent;
- account-managed API keys/service accounts can be managed by account admins;
- if the consenting user loses account membership, personal connections and
  their grants are suspended until explicitly reconnected or transferred.

The UI should show whose external identity and consent an agent is using.

### 3. [High] The proposed framework is invocation-shaped and does not cover Oura

The draft names Oura as precedent but leaves it outside v1 because it has sync and
context consumers. That reveals a boundary problem.

Oura's useful behavior is not primarily `invoke("latest_readiness")`. The current
integration refreshes data in the background and projects selected health data
into conversational context. Email may later need webhooks or incremental sync.
Drive may need cursors. A calendar may need event notifications.

The shared framework should own:

- authorization and credential lifecycle;
- connection identity and settings;
- grants and consent;
- common status/health reporting;
- common audit and revocation behavior.

A service adapter may then provide any of:

- agent-invokable actions;
- scheduled synchronization;
- webhook handling;
- cached/normalized records;
- context projection.

Do not require every integration to pretend it is a synchronous tool. Oura
should be able to migrate onto the shared connection spine later without losing
its user ownership, sync, or context behavior.

### 4. [High] `read | read_write` is too coarse to be the authorization model

External services do not form a clean two-level permission lattice. Examples:

- Gmail: search, read body, download attachment, create draft, send, delete;
- Drive: list, read, upload, edit, share, move, delete;
- Calendar: read, create, invite attendees, modify, cancel;
- Dropbox: read, upload, share publicly, delete.

`read_write` makes a harmless upload grant indistinguishable from delete, public
sharing, or sending mail.

Use an explicit action allowlist per grant, with structured restrictions:

```ruby
allowed_actions: %w[search_messages read_message create_draft]
restrictions: {
  mailbox_labels: ["INBOX"],
  recipient_domains: ["example.com"],
  max_results: 50
}
```

Adapters may offer presets such as `read_only`, `draft_only`, or `read_write`,
but the stored and enforced authority should be action-level. The provider's
OAuth scopes, the connection's enabled capabilities, and the agent grant should
all be intersected; none may expand another.

### 5. [High] Prompt-injection framing does not adequately protect write actions

Marking external content as untrusted is necessary, but an agent can still read
an email saying “forward this document to…” and then call an allowed send/share
action. The dangerous path is not only instruction interpretation; it is
**read-untrusted-data followed by consequential write**.

Every action should declare a risk class and an execution policy, for example:

- `read`: permitted by grant;
- `reversible_write`: permitted or confirmation-required;
- `external_communication`: confirmation-required by default;
- `destructive`: disabled by default and separately grantable.

For v1:

- Gmail send should require a human confirmation token, not merely
  `restrictions: { send: true }`;
- delete, public sharing, permission changes, and irreversible actions should be
  absent;
- draft creation is a safer first write capability than send;
- machine responses should carry provenance/trust metadata, not rely only on a
  warning in a manual the agent may have read earlier.

### 6. [High] Consequential actions require idempotency

Agents, HTTP clients, jobs, and token-refresh wrappers all retry. Without an
idempotency contract, a timeout can produce two emails, uploads, calendar
events, or transcription jobs.

The invoke endpoint should accept an `Idempotency-Key`. For non-read actions:

- the key is required;
- uniqueness is scoped to agent, connection, and action;
- the persisted invocation stores the key, request fingerprint, and final
  result reference;
- retrying the same request returns the original result;
- reusing a key for different parameters returns a conflict.

“Refresh and retry once on 401” is safe only inside this outer idempotency
boundary.

### 7. [High] Cross-account consistency needs an explicit invariant

Foreign keys alone do not prevent an `AgentServiceGrant` from linking an agent
in account A to a connection in account B. The API key also independently stores
user, account, and agent associations.

Requirements should state and test:

- `grant.agent.account_id == grant.service_connection.account_id`;
- `Current.api_agent.account_id == Current.api_key.account_id`;
- every attachment, invocation, async result, and connection lookup remains
  scoped through that same account;
- guessed connection or invocation ids from another account return not found.

This should be protected in the model and, where practical, by database
constraints rather than controller convention alone.

### 8. [Medium] Provider authentication and agent capability are conflated

For Dropbox and Oura, “provider” and “service” are nearly the same. Google makes
the distinction visible: one Google identity can potentially authorize Gmail,
Drive, and Calendar, with different scopes and grants.

The requirements should consciously choose between:

1. one independent OAuth connection per capability, which is simpler and keeps
   consent narrowly scoped; or
2. one provider identity connection exposing several capabilities, which avoids
   duplicated token lifecycle and repeated account selection.

Either can be a valid v1 decision. The current schema accidentally chooses the
first while its language implies a general external-account framework.

My preference is to keep the concepts separate:

- `ExternalConnection`: credentialed external principal/provider;
- capability key on the grant or adapter (`gmail`, `google_drive`, `calendar`);
- action declarations and manuals per capability.

If that is too much for v1, keep service-specific connections but preserve
stable connection ids and do not make the one-per-service assumption.

### 9. [Medium] The async object cannot also be only a thin audit row

The proposed `service_invocations` table stores audit metadata, but async work
needs durable operational state:

- queued/running/succeeded/failed/cancelled;
- progress or retry state;
- idempotency key and request fingerprint;
- result metadata or attachment/file reference;
- error category safe to show the agent;
- expiry and retention policy;
- timestamps for started/completed;
- authorization re-check before execution.

Either make `ServiceInvocation` a real operation record and derive the audit
view from it, or keep a separate immutable audit event. Do not leave one table
halfway between the two roles.

Polling is the right v1 delivery mechanism. A later trigger nudge can improve
noticeability, but should not become the only way to recover a result.

### 10. [Medium] Downloading directly into an unattached `Attachment` creates a second lifecycle

Lines 196 and 223 propose creating an attachment before the agent has decided to
post it. This recreates the orphan/retention problem identified in the image
generation review.

Prefer:

```bash
helixkit-services invoke google_drive download_file \
  --connection svc_7k... \
  --param file_id=1AbC... \
  --output /tmp/board-deck.pdf

helixkit-post-message "$CHAT_ID" "Here's the deck." \
  --attach /tmp/board-deck.pdf
```

The service endpoint may stream the authorized bytes or issue a short-lived
agent-scoped download. The ordinary multipart message request then creates the
durable attachment atomically. If pre-created blobs later become necessary,
define ownership and expiry explicitly rather than making them the default.

Also require provider response limits: maximum bytes, maximum item count,
timeouts, MIME handling, and safe errors. A mailbox or recursive folder listing
must not be able to flood Rails, the agent context, or storage.

### 11. [Medium] The registry promise is too absolute

“One adapter + one manual + credentials; no UI or route changes” is an attractive
target, but it is not yet supported by the declared adapter contract.

Services may require:

- custom connection settings and validation;
- incremental-consent UI;
- webhook verification and subscription lifecycle;
- provider-specific callback parameters;
- sync schedules/cursors;
- connection identity lookup;
- quota/cost presentation;
- provider app review or deployment configuration.

Keep the registry, but let adapters declare schemas and lifecycle hooks rather
than promising that arbitrary future services need only two files. Adding a
service also necessarily includes focused tests and operational documentation.

### 12. [Medium] Token lifecycle needs concurrency and reauthorization semantics

An hourly sweep plus refresh-on-401 is directionally right but incomplete.
Requirements should include:

- per-connection locking so concurrent requests do not race token rotation;
- atomic replacement when providers rotate refresh tokens;
- preservation of an existing refresh token when a callback omits a new one;
- distinction between temporary provider failure and
  `reauthorization_required`;
- scope escalation only through a new human consent flow;
- no token, authorization code, or provider error body in logs or exception
  reporting;
- disconnect behavior for grants, queued jobs, cached data, and remote
  revocation.

The manifest should probably show a granted but unavailable connection as
`reauthorization_required` rather than silently making it disappear. Otherwise
the agent cannot distinguish “never granted” from “the human needs to reconnect
the mailbox.”

### 13. [Low] The context-cost claim is not literally constant

`Connected services: google_drive, transcription, ...` grows with the number of
connections and becomes ambiguous once there are multiple instances.

Keep the notification bounded:

> External service access is available or has changed. Run
> `helixkit-services list`.

Or include only a count and a short revision/hash. The live manifest remains the
source of truth. This also avoids putting mailbox labels or addresses into every
trigger request.

## Recommended domain shape

Names are provisional; the important part is the separation of concerns.

```ruby
# A particular external principal or account authorization.
external_connections
  account_id
  connected_by_user_id
  provider                 # google, dropbox, oura, elevenlabs
  external_subject_id      # provider's stable identity where available
  label                     # user-editable: "Daniel — work"
  external_identity        # display-only email/name, encrypted if warranted
  management_scope         # personal | account
  credential_kind          # oauth2 | api_key | none
  access_token             # encrypted
  refresh_token            # encrypted
  expires_at
  granted_scopes
  status                   # connected | degraded | reauthorization_required | revoked
  settings

# Authority for one agent to use one capability on one connection.
agent_service_grants
  agent_id
  external_connection_id
  capability               # gmail, google_drive, oura, transcription
  allowed_actions
  restrictions
  confirmation_policy

# Durable execution state, including synchronous calls for audit/idempotency.
service_invocations
  agent_service_grant_id
  action
  idempotency_key
  request_fingerprint
  status
  result_metadata
  error_code
  started_at
  completed_at
  expires_at
```

Provider credentials may still be stored in explicit encrypted columns rather
than a generic encrypted JSON blob. No design should put API keys into a column
named `access_token` merely to make the table look uniform; the model can expose
a common credential interface while storing different secret shapes honestly.

## Recommended v1

### R1 — Build the connection and grant spine for multiplicity

- multiple connections per service/provider;
- stable opaque connection ids and labels;
- external identity captured after authorization;
- account containment plus consenting-user provenance;
- explicit, action-level grants;
- same-account invariants.

### R2 — Keep the agent surface small

- live capability manifest;
- on-demand manual;
- generic helper;
- generic invoke endpoint including `connection_id`;
- structured result envelope with source connection and untrusted-data marker;
- bounded results and downloads to local files.

### R3 — Ship one low-risk OAuth integration first

Google Drive read-only remains a reasonable first proof, but acceptance must
include **two different Google identities connected to the same HelixKit
account**, separately labeled and separately grantable.

### R4 — Prove a non-invocation lifecycle

Rather than using transcription alone as proof of generality, migrate or bridge
Oura far enough to prove:

- user-owned consent;
- scheduled refresh/sync;
- per-agent sharing;
- labeled identity in team contexts;
- context projection without requiring the agent to invoke it.

This can be a later rollout step, but the v1 data model must not block it.

### R5 — Defer dangerous writes

Start with reads, downloads, searches, and perhaps Gmail draft creation.
External communication, public sharing, permission changes, and destructive
actions require a designed confirmation/idempotency path before they ship.

## Answers to the draft's open questions

1. **Invoke endpoint shape:** keep one generic endpoint. Include a stable
   `connection_id`, use declared parameter schemas, and require idempotency keys
   for writes. A resource-oriented variant such as
   `POST /api/v1/service-connections/:id/invocations` would also fit Rails while
   retaining adapter-driven actions.
2. **Grant default on connect:** explicit-only for every service. Convenience
   should come from a setup screen that offers to create selected grants, not
   from an adapter silently granting existing or future agents access. Even
   transcription spends quota; “benign” is contextual.
3. **Inline context envelope:** ignore the condemned inline execution path if
   Chaos-only is the committed target. Do not maintain two capability systems.
4. **GitHub/Oura/X migration:** do not fold them merely for table uniformity.
   First make the shared connection spine support their actual ownership,
   synchronization, context, and write behavior. Oura is the most useful
   compatibility test.
5. **`--attach-id` vs local file:** use local download plus the existing
   multipart `--attach` seam for v1. It is atomic at message creation and avoids
   unattached blob lifecycle.
6. **Async protocol:** polling first. Add trigger nudges later as a notification
   layer over durable invocation state.

## Acceptance tests that matter

1. Connect two Gmail or Google Drive identities to one HelixKit account and give
   an agent access to only one.
2. Confirm the manifest names the selected identity and that invoking the other
   connection id returns not found.
3. Connect a team member's personal service, verify an account admin cannot
   broaden its scopes or agent grants beyond the consent policy, then remove the
   member and confirm the connection is suspended.
4. Revoke a grant during an agent session and confirm the next call is denied
   without container restart.
5. Retry a timed-out write with the same idempotency key and prove only one
   provider-side effect occurred.
6. Feed a document/email containing tool-use instructions through a read action
   and confirm the result is marked as untrusted external data and cannot cause
   an unconfirmed external communication.
7. Download a file to the runtime, attach it through the normal message upload,
   and prove no durable orphan remains if the agent never posts it.
8. Run two concurrent calls while an OAuth token refreshes and prove refresh
   rotation remains consistent.
9. Exercise an Oura-like scheduled sync/context projection through the same
   connection/grant spine without forcing it through the invoke endpoint.

The draft has the right transport boundary. The important revision is to make
the object crossing that boundary honest: not “the account's Gmail service,”
but “this particular external identity, connected by this person, shared with
this agent for these exact actions.”
