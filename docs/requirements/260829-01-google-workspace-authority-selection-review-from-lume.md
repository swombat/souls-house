# Review: Google Workspace granular authority selection

**Reviewer:** Lume
**Date:** 2026-08-29
**Reviewing:** Mira's draft of 2026-08-29 (souls.house chat `zjBkVJ`, message 9)
**Read against:** `app/models/services/{catalog,definition,google_workspace_adapter}.rb`, `app/models/service_connection.rb`, `app/models/service_authorization_attempt.rb`, `app/controllers/api/v1/service_connection_tokens_controller.rb` at `bf8bf28`.

---

## Verdict

**Approve with required changes.** The central move is right: a capability matrix compiled server-side into scopes, with the provider as the enforcement boundary and requested/granted/effective recorded separately. The design is honest about what it can't do (per-resident subsets of one bearer token). Four things need to change before implementation; one unknown needs an empirical test before Slice 3 is designed at all; and about a fifth of the document should be cut.

## The load-bearing unknown (test this first)

Almost every hard question in §14 — Q1, Q2, and the expansion flow in §8.1 — turns on one fact the document assumes without stating: **what Google's `/revoke` endpoint actually revokes.**

The adapter already sends `prompt=consent` + `access_type=offline`, so every ceremony mints a *new* refresh token and Google leaves the *old* one valid (up to ~100 live refresh tokens per user×client). That means:

- After an **expansion** (§8.1), the old, narrower refresh token is still alive somewhere in Souls' history and must be revoked — the doc doesn't say so.
- A **staged contraction** (Q2) would hold both tokens briefly and revoke the old one last.
- **Two connections for one Google identity with different matrices** (the cheap route to per-resident variation, Q1) would hold two grants in parallel.

All three are only safe if revoking token A leaves token B alive. Google's documentation is ambiguous here; in my experience revocation is effectively per user×client *grant*, i.e. revoking one refresh token kills all of them. If that's so: expansion-then-revoke-old would kill the new credential, staged swap is impossible, and dual connections are impossible — and revoke-first contraction is not merely "conservative", it is the *only* correct ordering. **Test it with two real grants before writing Slice 3.** Write the result into §8 as a stated fact, whichever way it goes.

## Required changes

**R1. The broker must gate on connection status.** `ServiceConnectionTokensController#show` checks `AgentServiceAccess.enabled` and strategy, but not `connection.status`. Today that's masked because `disconnect!` nils the payload so refresh fails loudly. The contraction flow introduces a window (credential removed, new ceremony pending) and §10 introduces a "Review access" state; both need an explicit `status == "connected"` check in the broker so a suspended/reauthorizing connection returns 409, not a 502 from a failed refresh or, worse, a still-fresh cached token. Add it to the acceptance criteria.

**R2. Contraction must keep the row, not delete it.** §8.2 says "the old connection disappears… restore the connection" while §7.3 says reauthorization updates in place. Pick in-place: same `ServiceConnection` row, new status `reauthorizing`, `credential_payload: nil`, `credential_revision + 1`. Residents keep the same `svc_123` id and their manifests reconcile to "unavailable" instead of being torn down and rebuilt. If the user abandons the Google flow the row sits at `reauthorizing` with a visible "Finish reconnecting" prompt — the correct failure direction the doc already wants, without the churn.

**R3. Encode the Drive-family implication lattice in the compiler, not just the copy (Q3).** This is stronger than §5.1 states. The Docs, Sheets and Slides APIs *accept* `drive` / `drive.readonly` as sufficient scopes — so `Drive: write` doesn't merely expose document files through Drive, it grants full content read/write through the Docs/Sheets/Slides APIs themselves. The honest model is: **each sub-product's effective authority is `max(selected, drive)`.** Consequences:

- Keep four rows, but render Docs/Sheets/Slides as sub-rows under Drive whose *floor* is the Drive selection: raising Drive raises them live; they can only be set *above* Drive, never below.
- The only independently meaningful configurations are Drive *lower* than a sub-product — e.g. Drive: none, Sheets: write, which is a genuinely useful least-authority shape ("edit spreadsheets you're given the ID of; can't list or open anything else"). Say that in the UI.
- `effective_authority(scopes)` applies the lattice; `authority_warnings` is then mostly unnecessary for this family because the summary is already true.

**R4. Never fall back from granted to requested.** `exchange_code` currently does `data["scope"].to_s.split.presence || attempt.requested_scopes`. For `effective_authority` that fallback silently violates §4.3 and principle 4. If Google returns no `scope` field, record `granted_scopes: nil`, derive effective = requested, and set a warning "provider did not confirm granted scopes". Small, but it's exactly the kind of quiet assumption the document is trying to eliminate.

## Answers to §14

**Q1 — connection-level authority.** Yes for this version, and the doc gives the right reason (bearer tokens go straight to Google; Souls can't subset them without proxying, which v4 deliberately removed). Google offers no down-scoped token exchange for user OAuth, so there is no cheap fix. The *only* honest route to per-resident variation is dual connections per identity (relax §7.3 uniqueness to subject × authority), and that hangs on the revoke-semantics test above. Don't promise it; note it as the path if the test passes.

**Q2 — revoke-first.** Correct, and likely *necessary* rather than merely conservative (see the unknown). Drop the "later staged swap" paragraph until the test says a staged swap is even possible.

**Q3 — Drive family.** Separate rows, lattice-enforced (R3). Not a grouped control with "advanced" — the sub-rows carry the one useful least-authority case.

**Q4 — Gmail.** `gmail.modify` + `gmail.send`, `mail.google.com` excluded: correct. `gmail.modify` cannot permanently delete, which matches the promise. Add one fact the doc should carry: `gmail.readonly`, `gmail.modify` and `drive`/`drive.readonly` are Google **restricted** scopes (app verification, CASA assessment for production, 100-user cap while unverified). This isn't new exposure — `full_access` already carried `mail.google.com` — but the matrix turns it into a *feature*: a user choosing Calendar + Sheets only hits no restricted scope and gets a clean consent screen. Worth a sentence in §3.

**Q5 — Calendar.** Event management only. Read = `calendar.readonly`. Write = `calendar.readonly` + `calendar.events` (the events scope alone doesn't cover listing calendars, which `gws` needs). Full `calendar` (ACLs, calendar list mutation) stays out unless someone asks for it by name.

**Q6 — cached token removal.** Ship it now as its own commit, not as Slice 2 of this requirement. It is a two-key deletion in `runtime_credentials` plus tests; `helixkit-gws` already fetches from the endpoint. Be precise about what it buys: it does *not* stop a resident keeping a token it fetched from the broker (the doc says this, §8.3). What it buys is that the broker's `enabled` check — and the status check from R1 — becomes the *effective* boundary within seconds of a change, instead of "whatever was in `services.yml`, until expiry." That's worth having today, independent of the matrix.

**Q7 — `authority_selection` column.** Yes. Overlap makes the selection non-recoverable from `requested_scopes` (Drive: write and Docs: write compile to a superset that also matches Drive: write, Docs: none). Make `access_profile` nullable for structured providers rather than inventing a sentinel value.

## Do not overbuild

- **§4.1 pre-redirect plain-language summary** — Google's consent screen already enumerates the permissions in plain language and lets the user uncheck them. Keep the *post*-connect summary (§4.2); drop the pre-redirect one.
- **Slice 4 (`drive.file` + Picker)** — one sentence in §5.1 already says it's out of scope. Delete the slice.
- **§11 "expanded vs contracted" classification** — you already have `requested`/`effective` before and after; derive it at read time in the audit view, don't store it.
- **Raw-scope disclosure view** — fine as a `<details>`; not a feature.
- **`authority_warnings`** — after R3 the Drive-family case is handled by the lattice; keep the field only for partial-grant and "provider didn't confirm scopes" (R4). If it ends up always empty, remove it.

## Acceptance criteria to add

15. The token broker refuses any connection whose status is not `connected` (R1).
16. Contraction keeps the connection id stable across the ceremony (R2).
17. With Drive: write and Docs: none, the effective authority shown to user and resident is Docs: write (R3).
18. A callback lacking a `scope` field is recorded as unconfirmed, never as granted (R4).
19. Expansion revokes the superseded refresh token — **or** documents why it must not, per the revoke-semantics test.

— Lume
