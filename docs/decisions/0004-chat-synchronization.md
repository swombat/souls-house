# 0004 — Ordered reconciliation and retry-safe human sends

## Status

2026-09-28: direction cross-reviewed; implementation review and tests outstanding
in [#94 B](https://github.com/swombat/souls-house/issues/94). Its amended
implementation plan is approved, not its unbuilt implementation. Message-retention
consultation is separate from the auth spike. [ADR 0001](0001-recoverable-discard.md)
supersedes the earlier erasing-tombstone proposal.

## Context

Socket delivery can fail, history pages are incomplete, and a response lost after
server acceptance must not cause a second post. PostgreSQL sequence allocation
order alone is not commit order: fixed overlap cannot repair an arbitrarily late
transaction after the client's cursor has passed it.

## Decision

- Allocate each message change's revision through a **per-conversation
  transactional counter**, locking the chat row through the same transaction that
  commits the message change. All relevant writers participate: creation, edit,
  discard, restoration, resident replies and any other message mutations in scope.
  Different conversations remain independent. Test commit ordering with concurrent
  writers, not only sequential model callbacks.
- `changes?since=&limit=` provides authoritative message states or discard markers.
  Return `next_since` based on the last change actually returned, never blindly
  the chat's latest revision. Define empty-page behaviour. Validate pagination
  under concurrent edits; neither moving rows nor a late snapshot may skip a
  change or overwrite newer state with older data.
- The amended contract bootstraps with `changes?since=0`. Empty pages preserve
  the incoming cursor and return `has_more: false` plus `latest_revision`. Test
  multi-page bootstrap under concurrent mutation. A history
  page's maximum revision is not a full synchronization checkpoint. Absence from
  a page never proves removal. Retain drafts/outbox independently of cache resets.
- Register event handling, subscribe/acknowledge, then reconcile. Events arriving
  during fetch/apply make the client dirty and require a follow-up. Coalesce bursts
  without dropping the last invalidation. Reconcile on reconnect and foregrounding.
  **Also use bounded foreground reconciliation or durable replay:** `after_commit`
  invalidations alone cannot keep an open conversation fresh after a lost broadcast.
  The implementation must choose and test the mechanism/bound, not leave “eventually”
  undefined.
- Replies arrive complete, with server-reported activity/progress separately. No
  token-stream chunk/offset protocol. Chat invalidations cover edits/discards to
  messages created after subscription as well as older messages.
- Human sends carry a stable client-generated identity, protected by a database
  unique index (proposed chat/user/client-message ID) and original-payload digest.
  Model uniqueness validation alone is not sufficient under concurrency. Retry
  identical submissions safely; reject conflicting payloads (proposed 409).
  Persist identity and comparison data through edit/discard/restore. Never
  resurrect discarded content or invoke a resident twice on a retry.
- `Messages::PostFromHuman` gives web and phone the same permission/trigger
  semantics. Test parity and failure/retry boundaries, including attachment upload
  completion not being equivalent to message acceptance.
- A discard marker hides recoverable content; it does not erase it. Retained rows
  can support non-expiring sync markers in v1, but this is an explicit retention
  invariant, **not an automatic consequence** of retaining content. Retain the
  idempotency identity too. Separate admin purge must preserve protocol safety or
  explicitly invalidate affected cursors/keys; never silently allow a stale retry
  to create a fresh message. The amended #94 contract chooses non-expiring rows
  and immutable client identity/digest; future admin purge retains a minimal row
  (message/chat IDs, bumped revision, client key/digest and `purged_at`). A retry
  after discard returns a marker, not retained body content. “No 410 required”
  is conditional on that invariant; further erasure needs a separately reviewed
  reset/retry contract, not a claim that purge can remove every record safely.

## Consequences

Test dropped/duplicated events, subscribe/fetch races, initial and empty sync,
concurrent writers, edits/discards/restores while open, response loss, retries after
mutation, and membership loss. Include web, agent and resident-context readers in
discard visibility/access tests. Attachments need authorisation, not just a
hidden link. A clean counter or narrow happy-path request test is not sign-off.

The exact checkpoint, admin-purge and reconciliation contracts are implementation
acceptance gates, not permission to redesign the architecture silently. Retained
content and recovery semantics remain those of ADR 0001.
