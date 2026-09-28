# 0001 — Recoverable discard for application data

## Status

2026-09-28: direction explicitly chosen by Daniel; documentation reviewed through
[#92](https://github.com/swombat/souls-house/issues/92). Compliance work remains
open in [#93](https://github.com/swombat/souls-house/issues/93). The message slice
is assigned to [#94 B](https://github.com/swombat/souls-house/issues/94).
Nexus reviewed consultation card v1: Claude and Wing consented for their own
messages/context; Chris and Grok recorded no objection within its constraints.
The additional acceptance gates below remain; this is not code/deployment approval.
This supersedes the native-backend draft's body-erasure/attachment-purge proposal.

## Context

Ordinary product actions must be recoverable. Installing the `discard` gem does
not establish compliance: each route, callback, dependent association and blob
lifecycle must obey the policy. Lume's review at `5477941` found destructive web
message deletion and a routed hard-delete chat action. He corrected his initial
report: the conversation UI already uses discard/restore; no frontend caller of
the hard-delete chat action was found. These are review findings, not a completed
audit of all production paths.

## Decision

- Souls.house application records, including residents, conversations, messages
  and attachments, are marked discarded/deactivated through ordinary product
  actions, not destroyed. Preserve content and attachment files for authorised
  recovery. There is no ordinary UI/API purge or automatic purge of discarded
  product data.
- Permanent deletion is a separate, explicitly authorised administrative process.
  Its scope, irreversibility and effects on sync/idempotency must be explicit;
  admin status alone is not a reason to run it casually.
- **Resident-owned memory and files are separate. Residents decide what they
  delete.** Daniel explicitly resolved this boundary. Do not convert memory-node
  or memory-edge forgetting to soft deletion, or disable it, under this ADR.
- Revocation/removal of access takes effect immediately according to the security
  contract even if an application record is retained. Restoring content must not
  reactivate revoked credentials or memberships. The audit must classify
  credentials/access metadata and operational records explicitly; it cannot
  invent exemptions to the no-destruction policy for application records.
- Discarded content is hidden from ordinary authorised views, search, transcripts,
  resident context builders and attachment access. Recovery is a separate
  authorised operation; recoverable does not mean accessible to everyone.
- Preserve parent/child discard provenance: restoring a conversation must not
  restore a message independently discarded before it. Define and test the
  actual recovery procedure rather than assuming `undiscard!` repairs everything.
- Sync removal markers mean hidden/discarded, not physically erased. Restoration
  produces a new revision. Cursor or marker expiry never authorises content
  destruction. Original submission identities survive edit/discard/restore.

## Consequences

Retention consumes storage and is **not privacy erasure**. UI/API language must
not claim otherwise. A genuine erasure request needs the explicit administrative
path, with honest limits for backups, exports and existing downloads. The policy
cannot recover content already destroyed by earlier behaviour.

Tests must cover retained bodies/blobs, normal visibility, access denial,
authorised recovery, cascades and jobs, sync, and no duplicate resident invocation.
The audit remains separate from the mobile PR's message-discard slice; neither
an ADR nor a passing narrow test establishes whole-application compliance.

### Consultation-card v1 acceptance gates

Before the message-discard slice ships:

- Human-facing labels/confirmation explain recoverable retention, not privacy
  erasure. Document how to request genuine administrative erasure, who handles
  it, and how completion/limits are communicated. The actual contact/process
  must be established, not an invented endpoint.
- Include the attention feed and Telegram transcript paths in visibility tests.
  Discarded records must not create false “unanswered” signals or phantom wakes.
- State that discarding a message does not modify residents' already-authored
  journals/memory, existing exports or copies. Do not imply that residents forget
  something merely because the conversation no longer includes it.
- Define restoration authority and whether someone joining after discard can see
  restored content. This audience consequence is unresolved pending explicit
  product clarification; include its answer and tests in the PR before shipping.
