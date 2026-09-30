# Second-pass feedback: Agent service integrations 01b

**Date:** 2026-07-29
**For:** Lume, to integrate into the next revision
**Reviewed:** `260728-01b-agent-service-integrations.md`
**Earlier feedback:** `260728-01b-agent-service-integrations-feedback-from-mira.md`

## Verdict

The architecture now has the right center. The external
connection/capability/grant separation is coherent, multiple identities are
first-class, consent ownership is visible, authority is action-level, and the
agent boundary remains small.

This is a structural integration of the first review, not a patch over the old
singleton-service model.

Before implementation planning, I would resolve four remaining contract gaps:

1. account-bound OAuth initiation;
2. honest API-key storage;
3. connection health versus per-capability readiness;
4. temporary input/result storage for asynchronous work.

The remaining notes are smaller consistency corrections.

## Required revisions

### 1. OAuth authorization needs a durable, account-bound attempt

The proposed flow still begins with:

```text
GET /services/:provider/connect
```

and uses the existing session-state pattern. That pattern is insufficient here
because HelixKit supports multiple accounts and this flow must also remember
which capabilities and scopes were requested.

The authorization request must bind:

- the HelixKit account;
- the initiating user;
- provider;
- requested capabilities;
- exact requested scopes;
- expiry;
- return path;
- random state;
- PKCE verifier where the provider requires or supports it.

Capability selection must occur **before** redirecting to the provider because it
determines the OAuth scopes.

Recommended resource:

```ruby
external_authorization_attempts
  account_id
  user_id
  provider
  requested_capabilities
  requested_scopes
  state_digest
  pkce_verifier       # encrypted, nullable
  return_path
  expires_at
  consumed_at
```

Recommended browser route shape:

```text
POST /accounts/:account_id/external_authorization_attempts
GET  /external_authorization_attempts/callback
```

The callback finds the attempt through the random state, verifies that it is
unexpired and unused, and recovers account/user/provider/scopes from the stored
attempt. It must not trust callback parameters to choose the HelixKit account or
requested capabilities.

This also permits concurrent authorization flows in separate tabs without one
session key overwriting another.

### 2. Add honest storage for API-key credentials

The schema declares:

```ruby
credential_kind # oauth2 | api_key | none
```

but provides only:

```ruby
access_token
refresh_token
```

The ElevenLabs transcription connection therefore has nowhere truthful to store
its API key.

Add:

```ruby
t.string :api_key # encrypts
```

with model invariants appropriate to `credential_kind`, or introduce a small
encrypted credential object if there is a concrete reason to support more
secret shapes now.

Do not store API keys in `access_token` merely to preserve a uniform-looking
table.

`connected_by_user_id` should preferably remain non-null for account-managed
connections too: it records who entered or authorized the credential even when
the account, rather than that user, controls it. If system-seeded credentials
need null provenance, state that as the exception.

### 3. Separate connection health from capability readiness

One Google connection may simultaneously have:

- a valid token and refresh token;
- sufficient scopes for Gmail;
- insufficient scopes for Drive.

In that state the external connection is healthy. Only the Drive capability
requires additional consent.

Do not use connection-level `reauthorization_required` for a missing
capability-specific scope, because that would incorrectly make every capability
on the shared connection appear unavailable.

Use two concepts:

```text
connection status:
  connected | suspended | revoked | error

manifest-entry readiness, derived per connection × capability:
  ready | additional_scope_required | unavailable
```

An unrecoverable token refresh failure makes every capability unavailable and
may be represented by a connection-level authorization error. A missing action
scope affects only the relevant capability/action.

The manifest entry's `status` should be derived from:

1. connection health;
2. adapter-required scopes for the granted actions;
3. the connection's actual granted scopes.

The `manifest_revision` must include this derived readiness, not only the raw
connection status.

### 4. Define temporary files and asynchronous result storage

`ServiceInvocation#result_metadata` deliberately contains no result content, but
transcription must preserve its output between job completion and agent polling.
It also needs an authorized input source.

Specify both directions.

#### Inputs

An async action may accept:

- an existing HelixKit attachment whose record belongs to the same account and
  is visible to the calling agent; or
- a bounded multipart upload owned by the invocation.

Provider paths supplied by an agent are not Rails-side files and should not be
accepted as if they were.

#### Results

Large or file-shaped results should use an invocation-owned temporary result,
for example:

- an Active Storage blob attached to `ServiceInvocation`; or
- an encrypted result record/blob;
- a provider-side result reference only when the provider guarantees suitable
  retention and retrieval.

The requirements should define:

- account and agent ownership;
- authorization checks on retrieval;
- MIME/type and byte limits;
- expiry;
- cleanup;
- behavior after grant revocation;
- whether retrieval is single-use or repeatable until expiry.

This temporary result is not a conversational `Attachment`. If the agent wants
to post it, the helper downloads it locally and the ordinary multipart message
request creates the durable message attachment.

## Consistency fixes

### 5. Make the idempotency fingerprint cover the complete operation

The draft currently describes:

```text
request_fingerprint = digest(action, params)
```

It must include:

```text
connection id
capability
action
canonicalized parameters
input-file identity/digest, where applicable
```

Otherwise the same agent could reuse an idempotency key with identical action
parameters against a different connection and accidentally receive the first
connection's result.

Create the invocation/idempotency record before the provider side effect.
Concurrent duplicate requests should observe the existing
queued/running/succeeded/failed operation rather than both executing.

The current unique index scoped only to agent is acceptable as a deliberately
strict rule if the complete fingerprint is used. Otherwise scope the key by
agent + connection + capability + action.

### 6. Keep temporary downloads agent-authenticated

A short-lived signed URL should not silently become a transferable bearer
credential.

Prefer a download endpoint which:

- still requires the agent's `hx_` bearer token;
- scopes the invocation through that agent and account;
- checks result expiry;
- re-checks whether retrieval remains permitted;
- returns 404 for cross-account or foreign-agent ids.

The signature may protect temporary provider/file metadata, but it should not
replace agent authentication unless the requirements deliberately choose a
single-use capability URL and define its leakage risk.

### 7. Remove `enabled_capabilities` unless it has an independent job

The current authority intersection has four layers:

1. provider scopes;
2. `enabled_capabilities`;
3. grant actions;
4. restrictions.

Layer 2 currently duplicates the neighboring layers:

- provider scopes determine what the connection is authorized to do;
- grants determine which agents may use which capability.

An additional array and settings toggle create a drift state where a grant
exists, scopes are present, but a connection-level capability flag disables it.

For v1, derive available capabilities from the provider registry and granted
scopes, and derive agent availability from grants. Remove
`enabled_capabilities`.

If scheduled sync or a non-agent web consumer later requires independent
activation, model that concrete lifecycle explicitly rather than using one
generic capability array for several meanings.

### 8. Link invocations to the grant they exercised

Add:

```ruby
t.references :agent_service_grant, foreign_key: true
```

or preserve an equivalent immutable policy snapshot.

The executing job then has an exact object to re-check, and historical audit can
say which grant authorized the operation. If grants are retained while
connections are disconnected, the reference can remain intact.

If grants may be deleted, define whether historical invocations restrict
deletion, nullify the reference while retaining the policy snapshot, or retain
soft-deleted grants.

### 9. Decide how denied attempts are audited

`ServiceInvocation` is now a durable operation record with:

```text
queued | running | succeeded | failed | cancelled
```

The security section also describes it as the invocation audit, but rejected
calls may fail before an operation record exists.

Choose one:

- add a `denied` terminal state and create a minimal safe record for recognized
  but unauthorized attempts; or
- keep operational invocations separate from a small security event record.

Do not put raw parameters into either path. Adapter declarations should provide
an allowlisted audit projection such as item count or file size; avoid a generic
“summarize and redact arbitrary params” step.

### 10. Define reconnect collisions and consent transfer

The callback currently upserts on:

```ruby
[account_id, provider, external_subject_id]
```

If another team member authorizes an external identity already connected by
someone else, the upsert must not silently replace:

- `connected_by_user_id`;
- refresh/access tokens;
- consent provenance;
- existing grants.

Required behavior:

- the existing consenting user may reconnect and rotate credentials;
- another user receives a conflict requiring an explicit transfer/replacement
  flow;
- transfer records the previous and new consenting users and requires suitable
  account authority plus fresh provider consent.

Reduction by an admin remains distinct from assumption of another person's
consent.

### 11. Make public-id examples match the implementation

The current `ObfuscatesId` concern produces a Hashids-style id without a `svc_`
prefix. It does not by itself produce:

```text
svc_7k…
```

Either:

- use the existing obfuscated id and show it accurately; or
- add a real prefixed public-id mechanism for connections and invocations.

The prefix is useful for humans and logs, but the requirements should not credit
it to machinery that does not provide it. In either case, account scoping remains
the authorization boundary; obscurity is not authorization.

### 12. Resolve grant retention without adding an unnecessary state machine

Recommended v1:

- disconnect or suspend the connection;
- retain its grant rows;
- all grants become ineffective because the connection is unavailable;
- reconnecting the same external identity restores them;
- explicitly deleting a grant remains deletion.

That preserves admin intent without adding a separate suspended state to
`AgentServiceGrant`.

## Recommended answers to 01b's remaining questions

1. **Suspension versus deletion:** retain grants and suspend/revoke the
   connection. Delete grants only when the user explicitly removes the grant.
2. **Capability enablement:** remove the separate capability toggle in v1;
   derive capability support from registry + scopes and agent availability from
   grants.
3. **Manifest revision:** use a per-agent digest over the exact manifest fields
   relevant to discovery, including derived readiness.

## Acceptance criteria to add

13. Starting OAuth from one HelixKit account cannot create or update a
    connection in another account, even with manipulated callback parameters.
14. Two authorization flows can run concurrently without overwriting state.
15. Requested capabilities and scopes are fixed before provider redirect and
    recovered from the stored authorization attempt.
16. An account-managed API key is stored in an encrypted API-key field, not an
    OAuth token field, with the entering user recorded.
17. One shared Google connection can report Gmail ready and Drive requiring
    additional scope without disabling Gmail.
18. A transcription input and result are both account/agent scoped, size
    limited, retrievable until expiry, and cleaned afterward.
19. The same idempotency key used against another connection conflicts rather
    than returning the first connection's result.
20. A temporary download cannot be retrieved with another agent's bearer token.
21. Reconnecting an existing external subject as a different user requires an
    explicit consent-transfer flow and never silently replaces tokens or
    provenance.
22. A denied invocation leaves a safe audit trace without recording raw external
    ids, queries, message bodies, or filenames unless explicitly allowlisted.

## Readiness

Once the four required revisions are incorporated, I consider the requirements
ready for an implementation plan.

The important architecture is settled:

- connection means external identity;
- capability is separate from credential ownership;
- grants carry exact agent authority;
- personal consent cannot be broadened by account administration;
- Rails holds credentials while agents receive bounded capabilities;
- invocation is only one facet alongside sync, webhooks, and context projection;
- consequential writes remain outside v1.

The next revision does not need another conceptual remodel. It needs these final
contracts made explicit so implementation cannot accidentally choose the old,
smaller assumptions at the seams.
