# Google Workspace granular authority selection

**Date:** 2026-08-29  
**Author:** Mira, after discussion with Daniel  
**Status:** Revised requirement / design after Lume review  
**Related:** `260728-01e-agent-service-integrations.md`, `../plans/260808-01-agent-service-integrations.md`, `260829-01-google-workspace-authority-selection-review-from-lume.md`

---

## 1. Summary

Replace Google Workspace's current all-products `read_only` / `full_access`
profiles with a structured **authority selection**. Before connecting a Google
identity, the user chooses independently which Workspace products to expose and
whether each should be unavailable, read-only, or writable.

For example:

| Product | Selected authority |
|---|---|
| Drive | Read and write |
| Docs | Read and write |
| Sheets | Read and write |
| Slides | Read and write |
| Calendar | Read only |
| Gmail | None |
| Meet | None |

Souls compiles this selection into the exact OAuth scopes requested from
Google. The selection is validated and compiled server-side; the browser never
submits arbitrary scope strings.

Authority belongs to a `ServiceConnection`. Every resident provisioned with
that connection receives the same provider-enforced Google authority. Different
authority per resident is deliberately not promised by this version: residents
call Google directly with a bearer token, so Souls cannot honestly enforce
different subsets of one token's authority.

As an immediate security prerequisite, remove cached provider access tokens
from resident service manifests. Residents receive only the Souls token-broker
endpoint; refresh tokens and cached access tokens remain inside Souls.

---

## 2. Problem

The current Google Workspace catalog defines two profiles:

- `read_only`: read access to Gmail, Calendar, Drive, Docs, Sheets, Slides, and
  Meet;
- `full_access`: broad write access to all of those products.

That forces unrelated trust decisions into one switch. A user cannot currently:

- share Drive without sharing Gmail;
- allow Calendar reading without Calendar mutation;
- allow document editing while keeping mail unavailable;
- express any other ordinary combination of product and authority.

Enumerating named profiles does not solve this. Seven products with three
states already produce thousands of possible combinations. The abstraction is
not "more profiles"; it is a structured selection which compiles into scopes.

---

## 3. Design principles

1. **The provider is the enforcement boundary.** A missing capability
   corresponds to a missing Google OAuth scope, not merely a prompt instruction
   or disabled UI control.
2. **Users choose capabilities, not scope URLs.** The UI speaks in products and
   understandable actions. Souls owns the scope mapping.
3. **Request the complete desired authority.** Each authorization ceremony asks
   for the exact desired scope set. Incremental accumulation must not silently
   preserve authority the user is trying to remove.
4. **Record requested, granted, and effective authority separately.** Google may
   return only a subset of requested scopes. The provider response is the fact.
5. **Authority contraction is security-sensitive.** Removing a capability must
   invalidate the previously broader credential before residents are treated as
   narrowed.
6. **Do not promise separations Google does not provide.** Drive authority
   implies authority in Docs, Sheets, and Slides. That relationship belongs in
   the compiler and UI, not only in explanatory copy.
7. **Keep the design generic without forcing every provider into it.** Dropbox's
   small profile list remains appropriate. Google opts into a richer catalog
   contract.
8. **A disabled or transitional connection cannot broker tokens.** The broker
   requires both enabled resident access and `connection.status == "connected"`.

---

## 4. User experience

### 4.1 Initial connection

The Google Workspace card replaces its profile dropdown with an authority
matrix:

| Product | None | Read only | Writable |
|---|---:|---:|---:|
| Drive | ○ | ○ | ○ |
| ↳ Docs | ○ | ○ | ○ |
| ↳ Sheets | ○ | ○ | ○ |
| ↳ Slides | ○ | ○ | ○ |
| Calendar | ○ | ○ | ○ |
| Gmail | ○ | ○ | ○ |
| Meet | ○ | ○ | ○ |

Product-specific labels replace generic "writable" where useful:

- Gmail: **None / Read only / Read, organize, and send**
- Calendar: **None / Read only / Manage events**
- Meet: **None / Read only / Manage meeting spaces**

The safest default is **None for every product**. The Connect button remains
disabled until at least one product is selected. Identity scopes (`openid` and
`userinfo.email`) are implicit and shown as "Identify the connected Google
account," not as a user-controlled product.

Google's own consent screen provides the pre-authorization permission summary.
Souls does not duplicate it with another confirmation step.

### 4.2 Drive-family controls

Docs, Sheets, and Slides remain visible as sub-rows because selecting one above
the Drive level is useful. Their effective minimum is the Drive selection:

- raising Drive from none to read raises Docs, Sheets, and Slides to effective
  read;
- raising Drive to write raises all three to effective write;
- a sub-product can be selected above Drive but never effectively below it.

For example, `Drive: none, Sheets: write` is useful least-authority access: the
resident can edit a spreadsheet whose ID it already knows without receiving
general Drive listing or browsing authority.

The controls update their effective values live rather than allowing an
impossible-looking combination and explaining it later as a warning.

### 4.3 Connected identity

The connection card shows effective authority as a readable list:

- Drive — read and write
- Docs — read and write
- Sheets — read and write
- Slides — read and write
- Calendar — read only
- Gmail — not shared
- Meet — not shared

It also offers **Edit Google access** and **Disconnect**.

Raw granted scopes may appear in a simple `<details>` disclosure for diagnosis,
but are not a separate product feature.

### 4.4 Partial or unconfirmed Google consent

After callback, Souls stores the exact scopes returned by Google and derives
effective authority from them.

If Google returns only a subset:

1. store the actual subset;
2. derive effective authority from that subset;
3. report requested capabilities which were not granted;
4. provision only effective authority.

If Google omits the `scope` field entirely:

1. store `granted_scopes: nil`;
2. derive provisional effective authority from the requested selection;
3. show a warning that Google did not confirm the granted scopes;
4. never record requested scopes as though the provider confirmed them.

The connection remains usable only if required identity authority and at least
one selected product capability are available.

---

## 5. Capability-to-scope mapping

The mapping belongs in the server-side service definition and must be verified
against the Google APIs and `gws` commands during implementation.

Identity scopes are always included:

```text
openid
https://www.googleapis.com/auth/userinfo.email
```

Initial mapping:

| Capability | Read only | Writable |
|---|---|---|
| Drive | `drive.readonly` | `drive` |
| Docs | `documents.readonly` | `documents` |
| Sheets | `spreadsheets.readonly` | `spreadsheets` |
| Slides | `presentations.readonly` | `presentations` |
| Calendar | `calendar.readonly` | `calendar.readonly` + `calendar.events` |
| Gmail | `gmail.readonly` | `gmail.modify` + `gmail.send` |
| Meet | `meetings.space.readonly` | `meetings.space.settings` |

Fully qualified Google scope URLs are implied in the table.

Do not use `https://mail.google.com/` for ordinary Gmail writable access. It is
broader than the product promise. Permanent deletion or mailbox administration
would require a separately named future capability with an explicit warning.

Calendar writable means event management. Full `calendar` authority—including
ACL and calendar-list mutation—stays unavailable unless requested as a distinct
future capability.

### 5.1 Drive implication lattice

The Docs, Sheets, and Slides APIs accept Drive-family scopes as sufficient
authority. The compiler therefore applies:

```text
effective Docs authority   = max(selected Docs authority, selected Drive authority)
effective Sheets authority = max(selected Sheets authority, selected Drive authority)
effective Slides authority = max(selected Slides authority, selected Drive authority)
```

This is stronger than file-level overlap. `Drive: write, Docs: none` grants
effective Docs content write through the Docs API and must be displayed that
way to both user and resident.

`compile_authority` produces the minimal predictable OAuth scope set.
`effective_authority` applies the implication lattice to requested or confirmed
scopes.

`drive.file` is not a drop-in replacement for `drive`: it covers files created
by or explicitly opened with the application. Supporting it well likely
requires Google Picker or an equivalent file-selection ceremony. It is out of
scope here.

### 5.2 Restricted-scope operations

Google classifies Gmail read/modify scopes and broad Drive scopes as restricted.
Production use may therefore require Google verification and a security
assessment; an unverified testing app is also subject to Google's test-user
limits.

This is not new exposure—the existing profiles already request broad mail and
Drive authority—but the matrix makes avoiding it a feature. A Calendar-and-
Sheets-only connection, for example, should request neither Gmail nor broad
Drive scopes.

---

## 6. Catalog contract

`Services::Definition` gains an optional richer authorization contract, named
here `authority_groups`:

```ruby
authority_groups: {
  drive: {
    name: "Drive",
    default: "none",
    options: {
      none:  { name: "None", scopes: [] },
      read:  { name: "Read only", scopes: [ GOOGLE_DRIVE_READ ] },
      write: { name: "Read and write", scopes: [ GOOGLE_DRIVE_WRITE ] }
    }
  },
  calendar: {
    name: "Calendar",
    default: "none",
    options: {
      none:  { name: "None", scopes: [] },
      read:  { name: "Read only", scopes: [ GOOGLE_CALENDAR_READ ] },
      write: { name: "Manage events", scopes: GOOGLE_CALENDAR_EVENT_WRITE }
    }
  }
}
```

The definition also provides:

```ruby
base_scopes: GOOGLE_IDENTITY
compile_authority(selection) # => requested scopes
effective_authority(scopes)  # => normalized selection + exceptional warnings
```

For Google, `effective_authority` applies the Drive-family lattice.

Providers without `authority_groups` continue using `access_profiles`
unchanged.

The serialized definition exposes group names, option keys, labels, defaults,
descriptions, parent/sub-row relationships, and useful warnings. It does not
need to expose raw scope URLs for form submission.

---

## 7. Authorization and persistence

### 7.1 Authorization attempt

`ServiceAuthorizationAttempt.begin!` accepts either:

- an `access_profile` for profile-based providers; or
- an `authority_selection` for structured providers.

For Google it:

1. rejects unknown product keys;
2. rejects unknown option values;
3. fills omitted products with `none`;
4. rejects a selection with no product authority;
5. compiles scopes server-side;
6. persists normalized `authority_selection` and compiled `requested_scopes`.

Add an `authority_selection` JSON/JSONB column to
`service_authorization_attempts`. Overlap makes the human selection
non-recoverable from scopes alone.

Make `access_profile` nullable for structured providers rather than inventing a
sentinel profile.

### 7.2 Connection metadata

No new `service_connections` column is required. Store:

```json
{
  "requested_authority": {
    "drive": "write",
    "docs": "write",
    "sheets": "write",
    "slides": "write",
    "calendar": "read",
    "gmail": "none",
    "meet": "none"
  },
  "granted_scopes": ["..."],
  "effective_authority": {
    "drive": "write",
    "docs": "write",
    "sheets": "write",
    "slides": "write",
    "calendar": "read",
    "gmail": "none",
    "meet": "none"
  },
  "authority_warnings": []
}
```

`effective_authority`, not `requested_authority`, drives the connection summary
and runtime documentation.

`authority_warnings` is reserved for exceptional facts such as partial grants
or missing provider scope confirmation. Drive-family implications belong in
effective authority and should not generate routine warnings.

### 7.3 Stable connection identity

The existing uniqueness model—one Google Workspace connection per external
Google subject within an account—remains.

A successful reauthorization updates the connection in place, increments
`credential_revision`, and reconciles every enabled resident access.

The `ServiceConnection` row and public `svc_123` ID survive expansion,
contraction, interruption, and successful reconnection.

---

## 8. Editing authority and the revocation prerequisite

Changing Google authority always uses a new OAuth ceremony. Souls does not
rewrite metadata and pretend an already-issued credential has become narrower.

### 8.1 Observed Google revocation unit

On August 29, 2026, we tested two real offline grants for the same Google user
and a temporary OAuth client:

1. Google issued distinct refresh tokens A and B;
2. both refreshed successfully;
3. revoking A returned HTTP 200;
4. five seconds later, both A and B failed refresh with HTTP 400
   `invalid_grant` ("Token has been expired or revoked.").

For this setup, revocation operates at the user × OAuth client grant level, not
at one refresh token. Therefore:

- staged credential swaps are impossible;
- parallel differently-scoped connections for one identity are unsafe;
- all authority changes are revoke-first and temporarily disconnect Google.

### 8.2 Expansion

Expansion uses the same revoke-first flow as contraction. The existing grant is
revoked and cleared before the new complete desired scope set is requested.

### 8.3 Contraction

Contraction keeps the same connection row and public ID:

1. warn that reducing authority temporarily disconnects Google;
2. set status to `reauthorizing`;
3. revoke the current provider credential;
4. clear `credential_payload`, increment `credential_revision`, and reconcile
   residents;
5. begin a fresh authorization for the narrower exact selection;
6. on callback, replace credential and metadata in place and restore
   `connected`.

Residents retain `svc_123` but see it as unavailable during the ceremony. If the
user abandons the Google flow, the row remains `reauthorizing` and the UI offers
**Finish reconnecting**.

This is less convenient than retaining broad authority behind a failed
downgrade, and therefore the correct failure direction.

### 8.4 Previously issued access tokens

An access token already delivered to a resident may remain valid until expiry
unless its provider grant is revoked. Reconciliation cannot pull a bearer token
back out of an untrusted process.

That fact is why contraction revokes before reconnecting and why cached-token
removal is an immediate prerequisite.

---

## 9. Runtime and broker boundary

The current refresh-broker runtime entry includes both:

- cached `access_token` and `expires_at`; and
- `access_token_endpoint`.

For every `refresh_broker` connection, the runtime manifest should contain only:

```yaml
credentials:
  access_token_endpoint: http://.../api/v1/service_connections/svc_123/access_token
```

`helixkit-gws` already fetches from that endpoint, so its interface does not
change.

The manifest exposes:

```yaml
access:
  authority:
    drive: write
    docs: write
    sheets: write
    slides: write
    calendar: read
    gmail: none
    meet: none
  scopes:
    - ...
  api_origins:
    - ...
```

Before issuing a token, the broker requires:

- enabled `AgentServiceAccess`;
- `credential_strategy == "refresh_broker"`; and
- `connection.status == "connected"`.

A suspended, revoked, errored, or reauthorizing connection returns a deliberate
conflict/unavailable response rather than attempting refresh or returning a
still-fresh cached token.

This change makes the broker's enabled/status checks the practical boundary
within seconds of reconciliation. It does not prevent a resident retaining a
token it previously fetched from the broker.

This version does not claim to mint different scope subsets per resident.

---

## 10. Existing connections

Existing Google connections were authorized under `read_only` or `full_access`.
Do not infer a finer-grained user intention from those profiles.

On deployment:

- preserve the credential and scopes so residents do not break;
- derive the best available effective authority from recorded scopes;
- mark the connection **Review access** in metadata/UI while leaving status
  `connected`;
- invite the owner to choose the new matrix and reauthorize;
- never silently add a scope.

Existing `full_access` connections using `https://mail.google.com/` carry a
visible warning until reviewed because ordinary Gmail writable is intentionally
narrower.

---

## 11. Auditing and reconciliation

Audit records for connect and edit operations include:

- requested authority selection;
- granted scopes or unconfirmed-grant state;
- effective authority selection;
- provider grant mismatch.

Expansion versus contraction is derived from before/after effective authority
in the audit view rather than stored as another fact.

Any effective authority or credential change increments `credential_revision`
and schedules reconciliation for every enabled `AgentServiceAccess`.

The resident manifest warning remains:

> The provider-enforced scopes and effective authority shown here are the
> authority available to this resident.

---

## 12. Acceptance criteria

1. A user can connect Google with Drive/Docs/Sheets/Slides writable, Calendar
   read-only, and Gmail/Meet unavailable.
2. The OAuth request contains no Gmail or Meet scopes for that selection.
3. Forged raw scope strings are rejected; only catalog option keys are accepted.
4. Callback stores Google's actual granted scopes and derives effective
   authority from them.
5. A partial Google grant is displayed as partial, never as the full request.
6. Residents receive no cached provider access token in `services.yml`.
7. `helixkit-gws` obtains a short-lived token and executes `gws`.
8. Calendar read-only cannot perform Calendar writes.
9. A connection without Gmail scopes cannot list or send mail.
10. Authority changes reauthorize and update the connection in place.
11. Contraction revokes/removes broad authority before narrower authority is
    considered active.
12. Existing Google connections work but are marked for access review.
13. Dropbox and profile-based providers retain current behavior.
14. The broker refuses any connection whose status is not `connected`.
15. Contraction keeps the connection public ID stable.
16. With Drive writable and Docs selected as none, effective Docs authority is
    shown as writable to both user and resident.
17. A callback lacking `scope` records an unconfirmed grant, never
    provider-confirmed requested scopes.
18. Expansion either revokes the superseded refresh token safely or documents,
    based on §8.1, why revoking it would destroy the replacement.
19. Calendar writable requests event authority without full calendar/ACL
    administration.

---

## 13. Implementation slices

### Immediate security prerequisite

- remove cached access tokens from all refresh-broker manifests;
- add the broker `status == "connected"` gate;
- update manifest, broker, and `helixkit-gws` tests.

Ship this independently rather than waiting for the matrix UI.

### Slice 1 — catalog and ceremony

- add `authority_groups` to `Services::Definition`;
- define and validate the Google mapping;
- add `authority_selection` to authorization attempts;
- make attempt `access_profile` nullable;
- render and submit the authority matrix;
- compile scopes server-side;
- store requested, granted, and effective authority;
- represent partial and unconfirmed grants honestly.

### Slice 2 — effective authority and presentation

- encode the Drive implication lattice;
- add structured effective authority to resident manifests;
- render post-connect summaries;
- mark legacy connections for access review.

### Slice 3 — editing

- add Edit Google access;
- implement revoke-first authority changes with stable connection identity.

---

## 14. Lume review outcomes and remaining question

Lume approved the central design with required changes. Her full review is
preserved in
`260829-01-google-workspace-authority-selection-review-from-lume.md`.

Decisions incorporated here:

1. connection-level authority is the honest boundary for this version;
2. per-resident subsets are not promised;
3. Drive/Docs/Sheets/Slides remain separate with a compiler-enforced Drive
   floor;
4. Gmail writable is `gmail.modify` + `gmail.send`;
5. Calendar writable means event management, not calendar administration;
6. cached-token removal and broker status gating ship immediately;
7. authorization attempts store explicit `authority_selection`;
8. contraction preserves the connection row and public ID;
9. missing provider scope confirmation is represented honestly;
10. pre-redirect duplication, a Picker slice, and stored expansion/contraction
    classification are not built.

The revocation question was answered empirically: revoking either refresh token
invalidated the whole user × client grant. The implementation therefore uses
one stable connection per Google identity and a revoke-first flow for every
authority change.

---

## 15. References

- Google OAuth 2.0 for web server applications:  
  `https://developers.google.com/identity/protocols/oauth2/web-server`
- Google Drive API scopes:  
  `https://developers.google.com/workspace/drive/api/guides/api-specific-auth`
- Gmail API scopes:  
  `https://developers.google.com/workspace/gmail/api/auth/scopes`
- Calendar API scopes:  
  `https://developers.google.com/workspace/calendar/api/auth`
