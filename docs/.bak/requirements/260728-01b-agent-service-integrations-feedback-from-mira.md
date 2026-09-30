# Feedback for 01b: Agent service integrations

**Date:** 2026-07-28
**For:** Lume, to integrate into the next requirements draft
**Source reviewed:** `260728-01-agent-service-integrations.md`
**Full review:** `260728-01-agent-service-integrations-review-from-mira.md`

## Overall direction

Keep the proposed:

- Rails-owned credential gateway;
- per-agent Rails-side grants;
- live capabilities manifest;
- on-demand service manuals;
- generic `helixkit-services` helper;
- adapter registry;
- tokens staying out of agent containers.

The transport boundary is right. The core revision is to model a connection as a
**particular external identity**, not as the HelixKit account's singleton instance
of a service.

## Required revisions for 01b

### 1. Support multiple connections to the same service

Remove:

```ruby
t.index [:account_id, :service], unique: true
```

HelixKit must support, within one account:

- multiple email accounts;
- personal and work Dropbox accounts;
- several team members' Oura accounts;
- any future provider connected under more than one identity.

Each connection needs:

- a stable opaque public id;
- a user-editable label such as `Daniel — work`;
- the provider's stable external subject id, where available;
- a display identity such as an email address or provider account name;
- a service/provider key;
- connection status and credential lifecycle.

The provider identity should be captured and displayed after OAuth. Uniqueness,
where possible, should be based on account + provider/service + external subject,
not account + service alone.

### 2. Separate account containment from human consent

Add `connected_by_user_id` and distinguish:

- **personal/delegated connections** authorized by an individual user;
- **account-managed connections** such as team API keys or service accounts.

Policy for personal connections:

- the consenting user controls reauthorization and scope expansion;
- account admins may disable grants or remove the connection from the account;
- account admins must not silently broaden another user's OAuth consent;
- losing account membership suspends the connection and its grants until it is
  explicitly reconnected or transferred.

The settings UI must show whose external identity is being delegated to which
agent.

### 3. Distinguish connection from capability

The draft currently uses `service` for both the credential relationship and the
agent-facing capability. Google makes the mismatch visible: one Google identity
may expose Gmail, Drive, and Calendar.

01b should name the distinction even if v1 implements service-specific OAuth
connections:

- **external connection**: credentialed provider identity;
- **capability**: Gmail, Google Drive, Oura, transcription, etc.;
- **grant**: an agent's allowed actions for one capability on one connection.

Preferred shape:

```ruby
external_connections
  account_id
  connected_by_user_id
  provider
  external_subject_id
  external_identity
  label
  management_scope
  credential_kind
  access_token
  refresh_token
  expires_at
  granted_scopes
  status
  settings

agent_service_grants
  agent_id
  external_connection_id
  capability
  allowed_actions
  restrictions
  confirmation_policy
```

If splitting provider connection from capability is too much for v1, retaining
`ServiceConnection` is acceptable, provided it still has stable connection ids,
labels, external identities, consenting-user provenance, and multiplicity.

### 4. Make invocation select a connection

The manifest and invocation API cannot identify only `gmail` or `dropbox`.

Manifest entries should look approximately like:

```json
{
  "connection_id": "svc_7k...",
  "service": "gmail",
  "label": "Daniel — work",
  "identity": "daniel@example.com",
  "status": "connected",
  "actions": ["search_messages", "read_message"],
  "manual": "/api/v1/capabilities/gmail/manual"
}
```

Invocation must include the stable connection id:

```http
POST /api/v1/service-connections/:connection_id/invocations
```

```json
{
  "action": "read_message",
  "params": { "message_id": "..." }
}
```

A single generic endpoint remains the preferred design. It preserves registry
extensibility without pretending there is only one instance of each service.

### 5. Store action-level authority, not only `read | read_write`

`read_write` is too broad. Sending mail, creating a draft, uploading a file,
sharing publicly, changing permissions, and deleting data should not all be one
permission.

Store an explicit `allowed_actions` set on each grant. The adapter may provide
UI presets such as:

- read only;
- read + upload;
- draft only;
- custom.

Enforcement is the intersection of:

1. provider OAuth scopes;
2. capabilities enabled on the connection;
3. the grant's allowed actions;
4. the grant's restrictions.

No layer may expand another.

### 6. Keep dangerous writes out of the first release

The untrusted-content warning is necessary but does not make writes safe. An
agent can read hostile instructions from a document or email and then use an
otherwise valid send/share action.

For v1:

- ship reads, searches, and downloads;
- optionally allow Gmail draft creation;
- do not ship Gmail send, destructive actions, public sharing, or permission
  changes;
- mark all external results with structured provenance and an
  `untrusted_external_data` trust classification.

Before consequential writes ship, define:

- human confirmation;
- action risk classes;
- idempotency;
- retry semantics;
- audit behavior.

### 7. Make the framework broader than synchronous invocation

Oura is a compatibility test for the abstraction. Its useful behavior is
scheduled synchronization and context projection, not primarily a live tool
call.

The common framework should own:

- authorization and credential lifecycle;
- external identity;
- consent and agent grants;
- status, revocation, and audit.

Adapters may additionally implement:

- agent-invokable actions;
- scheduled sync;
- webhook processing;
- cached or normalized data;
- context projection.

Oura does not have to migrate in the first implementation, but the 01b data
model and adapter contract must not prevent that migration.

### 8. Treat async invocations as durable operations

If transcription introduces asynchronous work, `ServiceInvocation` needs more
than audit metadata:

- queued/running/succeeded/failed/cancelled status;
- safe error code;
- result metadata;
- started/completed timestamps;
- expiry/retention;
- request fingerprint and idempotency key;
- authorization re-check when the job executes.

Use polling in v1. A future trigger nudge may announce completion, but must not be
the only way to recover the result.

### 9. Require idempotency for writes and job creation

Any non-read action or async job creation must accept an `Idempotency-Key`.
Retries with the same key and request return the original result. Reusing the key
with different parameters returns a conflict.

This must wrap token refresh and provider retries so a timeout cannot create two
emails, uploads, events, or transcription jobs.

### 10. Preserve the ordinary attachment lifecycle

Do not create an unattached durable `Attachment` merely because an external
service returned a file.

Preferred flow:

```bash
helixkit-services invoke google_drive download_file \
  --connection svc_7k... \
  --param file_id=1AbC... \
  --output /tmp/board-deck.pdf

helixkit-post-message "$CHAT_ID" "Here's the deck." \
  --attach /tmp/board-deck.pdf
```

The normal multipart message request creates the durable attachment atomically.
This avoids orphan storage and keeps the image-generation review's attachment
boundary intact.

Add provider response limits for item counts, payload bytes, timeouts, and file
types.

### 11. State and test the account-isolation invariant

Require:

```ruby
grant.agent.account_id == grant.external_connection.account_id
Current.api_agent.account_id == Current.api_key.account_id
```

All connection, invocation, result, and download lookups must remain scoped
through that account. Cross-account ids should return not found.

Protect this in models and, where practical, database constraints rather than
controller convention alone.

### 12. Complete token lifecycle requirements

Add:

- per-connection locking around refresh;
- atomic refresh-token rotation;
- preservation of an existing refresh token when a callback omits one;
- explicit `reauthorization_required` status;
- scope expansion only through a new human consent flow;
- log and exception filtering for tokens, authorization codes, and provider
  response bodies;
- defined behavior for grants, queued work, cached data, and remote revocation
  on disconnect.

A granted but unavailable connection should remain visible in the manifest as
`reauthorization_required`, rather than disappearing indistinguishably.

### 13. Soften the registry extensibility claim

Retain the registry, but replace:

> adding a service always means one adapter + one manual + credentials

with:

> the registry provides the common path; adapters declaratively contribute
> actions, parameter schemas, connection settings, and lifecycle hooks, with
> provider-specific jobs or webhook behavior where required.

Every new service will also require tests, provider registration/configuration,
and operational documentation. Avoid promising that arbitrary providers never
need UI, routes, or jobs.

### 14. Keep trigger context bounded

Do not append every connection name or email identity to every trigger. Use:

> External service access is available or has changed. Run
> `helixkit-services list`.

Optionally include a connection count or manifest revision. The live manifest is
the source of truth.

## Decisions on the existing open questions

1. **Invoke endpoint:** keep one generic invocation endpoint, scoped by stable
   connection id.
2. **Grant default:** explicit-only for all services. The connect screen may
   offer to create selected grants, but no silent auto-grant.
3. **Inline context path:** ignore it; build only for the committed Chaos-hosted
   end state.
4. **GitHub/Oura/X migration:** not v1. Design the shared spine to support their
   actual ownership and lifecycle before migrating them.
5. **Attachment handling:** download to the runtime and use existing multipart
   `--attach`; no `--attach-id` requirement for v1.
6. **Async completion:** polling first, optional trigger notification later.

## Revised rollout

1. **Connection spine**
   - multiplicity;
   - labels and external identities;
   - consenting-user provenance;
   - credential lifecycle;
   - account isolation.
2. **Grant spine**
   - capability + connection;
   - explicit action allowlists;
   - restrictions;
   - explicit-only assignment.
3. **Agent surface**
   - manifest;
   - manual;
   - generic invocation;
   - generic helper;
   - bounded trigger notification.
4. **First adapter**
   - Google Drive read-only;
   - test with two Google identities in the same HelixKit account.
5. **Non-OAuth/async adapter**
   - transcription;
   - durable polling and idempotent job creation.
6. **Non-invocation compatibility**
   - bridge or migrate Oura sufficiently to prove scheduled sync and context
     projection through the same connection/grant spine.
7. **Later**
   - Dropbox;
   - Gmail read;
   - Gmail drafts;
   - consequential writes only after confirmation and idempotency are designed.

## Acceptance criteria to add

1. Two connections to the same service coexist in one HelixKit account.
2. An agent granted one connection cannot discover or invoke the other.
3. The manifest clearly identifies the external account selected.
4. A personal connection cannot have its consent broadened by another account
   member.
5. Removing the consenting member suspends that connection.
6. Revoking a grant takes effect on the next API request without a restart.
7. Cross-account connection and invocation ids return not found.
8. Concurrent token refresh does not corrupt rotated credentials.
9. Retrying a write or async start does not duplicate provider-side effects.
10. External content is machine-marked as untrusted and cannot directly trigger
    an unconfirmed consequential action.
11. Downloading a file without posting it leaves no durable attachment orphan.
12. An Oura-like scheduled-sync/context integration can use the same connection
    and grant spine without pretending to be a synchronous invocation.

The concise replacement sentence for the architecture is:

> HelixKit stores named external identities authorized by users or accounts,
> grants selected agents exact capabilities on those identities, and exposes
> those capabilities through live invocation, synchronization, webhooks, or
> context projection without placing service credentials in agent runtimes.
