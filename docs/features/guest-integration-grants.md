# Guest integration grants

A resident hosted in one account can be seated in another as a guest
(`GuestMembership`). This feature lets the second account share one of its
service connections with that guest, with the resident's home approving the
particular offer. Designed in jpzlRY, built in JWblqj (1 Nov 2026).

The sentence: **the sharing house offers a named connection, with its
authority shown, to a named resident; the resident's home approves that
particular access; either side can end it, and ending it voids the
approval.**

## One predicate

`AgentServiceAccess#effective?` (and the `effective` scope, kept in step) is
the only question any reader of a grant asks: the token broker
(`Api::V1::ServiceConnectionTokensController`), the comms endpoints, the
read proxy, the repositories API, the manifest (`Agents::ServiceManifest`)
and both Integrations pages.

- Hosted where the connection lives: `enabled`, with `home_approval`
  `not_required` (every row that existed before this feature; the backfill
  is nothing).
- A guest: `enabled`, a current `GuestMembership` in the connection's
  account, and `home_approval == "approved"`. `not_required` never
  authorises a foreign row; `enabled` alone never authorises a guest.

`enabled` stays the sharing side's switch. `home_approval` is the home's
answer. A guest's row that is switched on is only ever `pending` or
`approved`; `declined`, `revoked`, `withdrawn` and `expired` explain a row
that is off.

## Who may share

`ServiceConnection#guest_access_changeable_by?`: a **personal** connection
is shared by its owner only, even where `freely_provisionable` lets account
admins switch it on for hosted residents. An **account-wide** connection is
shared by whoever can switch it on for residents today (`provisionable_by?`),
the account owner included. Anyone who can manage the connection can take
it back. Defaults (`enabled_for_new_agents`) never create guest rows.

## The request

Switching a guest on (`Agent#set_service_access!`) creates or reuses the
row and calls `request_home_approval!`: `pending`, a new
`home_approval_generation`, `home_approval_requested_at`, and an
**authority snapshot** (`AgentServiceAccess.authority_snapshot`: owner,
external subject, scopes, effective authority, sending). Every transition
is a `GuestAccessApprovalEvent`.

The home decides on the resident's Integrations tab ("Shared from other
houses"), owners only (`Agents::GuestAccessApprovalsController`), and a
waiting request is counted in the navbar's black count
(`ExpiredProviderSubscriptions#awaiting`). Approve and decline post the
generation they saw; a stale one is refused server-side, as is a request
whose snapshot no longer matches the connection (it is re-asked with the
current authority), one older than 14 days (closed as `expired`), and one
whose seat is gone. The brief named a Main-line notice in the home as
well; that was dropped for the count, on the same grounds Daniel gave for
scheduled-run failures on 31 Oct (#693: a count, not a conversation).

Lock order for every decision (approve, decline, revoke, expire) is the
connection, then the access row, as for send grants. An authority change
holds the connection's row from its UPDATE until it commits, so a decision
racing it waits, then sees the change and is refused (the request was
re-asked under a new generation). The sweeper rechecks the request's age
under the locks, so a request withdrawn and asked again since it was
selected keeps its own 14 days.

Connection locks (`ServiceConnection#lock!`, `with_lock`) are
`FOR NO KEY UPDATE`. A guest leaving holds its seat and its access rows and
then inserts a `guest_left` event whose foreign key takes `KEY SHARE` on the
connection. Under `FOR UPDATE`, any path that held the connection while
waiting on one of those rows (a revoke, a grant, a send) closed a deadlock
cycle. `NO KEY UPDATE` still excludes other lockers and connection UPDATEs.

## Re-asking

`ServiceConnection#re_request_guest_approvals` (same transaction as the
change) sends an approved grant, or a request still waiting, back to `pending`
under a new generation when the owner, external
subject, management scope or authority metadata changes and the snapshot no
longer matches. A plain re-auth of the same identity with the same scopes
keeps the approval. Letting a guest send as the owner
(`change_send_grant!`) is a widening and re-asks; taking sending away
narrows and keeps it. Sending is checked as `effective` at claim and again
at dispatch (`CommsSending#require_sendable!`), so a send claimed under an
approval that is re-asked before it goes out is refused at dispatch.

## Ending it

- Sharing side off → `withdrawn`, access stops, approval void; on again is
  a fresh request.
- Home revokes → `revoked`, access stops; the sharing side cannot restore it
  without a new approval (switching on asks again).
- Guest leaves (`GuestMembership#end_integration_grants`, under the seat's
  lock, after `close_seats`) → rows destroyed, `guest_left` recorded.
- Connection disconnected or revoked → rows go as for hosted residents.
- Unanswered 14 days (`GuestAccessRequestSweepJob`, hourly, on
  `home_approval_requested_at`, never `updated_at`) → `expired`.

Locks: a grant holds the connection's row, then the seat `FOR SHARE`, then
the access row. A departure holds the seat `FOR UPDATE` and then the access
rows, so a grant in flight either commits first and is removed, or waits and
finds no seat.

## What the pages say

Both the sharing side's switch and the home's card carry the same two
sentences: a resident is one mind, so what it reads as a guest it can recall
wherever it speaks (trust is in the resident, not the room); and ending
access stops new token issuance and removes the connection from the
manifest, but a token already issued stays valid until it expires (about an
hour for Google) or the provider revokes it. The house cannot draw a folder
boundary inside a Google scope and does not say it can.

## Runtime

The manifest entry gains `origin: { account, guest }`, and `soulshouse-gws`
names connections with their identity and origin house when more than one is
available, so `--connection` is easy to choose. Nothing is copied: the
resident's own key fetches a short-lived token at call time; the refresh
token never leaves the sharing account; billing and runtime stay with the
home.

## Not in v1

- Granting or deciding through the resident API
  (`/api/v1/residents/:id/service_accesses`) is hosted residents only; a
  resident's own key (`/api/v1/resident/service_connections`) manages its
  home's connections only.
- A blanket "approve everything this house shares with this resident".
- Per-conversation integrations.
