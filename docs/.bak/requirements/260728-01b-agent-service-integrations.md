# Agent service integrations — external identities, capabilities, and grants for Chaos-hosted agents

**Date:** 2026-07-28
**Author:** Lume (draft v2, integrating Mira's review)
**Status:** SUPERSEDED by `260728-01c-agent-service-integrations.md` (draft v3, post-second-pass) — supersedes `260728-01-agent-service-integrations.md`
**Review integrated:** `260728-01b-agent-service-integrations-feedback-from-mira.md` (all 14 revisions accepted; the connection-as-external-identity remodel is the structural one), full review at `260728-01-agent-service-integrations-review-from-mira.md`
**Related:** `260722-01-rubyllm-removal-chaos-only-agents.md`, `260725-01-agent-image-generation-review-from-mira.md`, `docs/plans/2026-05-07-mcp-to-skillfile-migration.md`, `docs/plans/260725-02a-runtime-managed-agent-documentation.md`

---

## 0. The architecture in one sentence

> HelixKit stores named external identities authorized by users or accounts, grants selected agents exact capabilities on those identities, and exposes those capabilities through live invocation, synchronization, webhooks, or context projection — without placing service credentials in agent runtimes.

## 1. What changed from v1

v1 got the transport boundary right (Rails-owned credentials, Rails-side grants, live manifest, on-demand manuals, generic helper, registry, tokens never in containers — all retained). Its structural error was modeling a connection as *the account's singleton instance of a service* (`unique [account_id, service]`). That breaks on the first second Gmail account. v2 remodels around three concepts:

- **External connection** — a credentialed provider *identity*: "Daniel — work Google", not "Google". An account can hold many per provider.
- **Capability** — an agent-facing surface: `gmail`, `google_drive`, `google_calendar`, `transcription`. One connection may expose several (one Google identity → Gmail + Drive + Calendar).
- **Grant** — one agent's exact allowed actions for one capability on one connection.

Other material changes: consenting-user provenance and personal-vs-account-managed consent policy (§4); explicit `allowed_actions` sets replacing `read|read_write` (§5); connection-scoped invocation API with idempotency (§6); no consequential writes in v1 (§8); durable async invocations (§7); download-to-runtime instead of server-side attachment creation (§6.4); account-isolation invariant with acceptance tests (§10); full token lifecycle (§9); bounded trigger context (§6.5); softened registry claim (§3).

## 2. Data model

```ruby
# external_connections — a credentialed external identity
create_table :external_connections do |t|
  t.references :account, null: false, foreign_key: true
  t.references :connected_by_user, foreign_key: { to_table: :users }  # null only for account-managed
  t.string  :provider, null: false          # "google", "dropbox", "elevenlabs"
  t.string  :external_subject_id            # provider's stable subject (Google `sub`, Dropbox account_id)
  t.string  :external_identity              # display identity: email address, account name
  t.string  :label                          # user-editable: "Daniel — work"
  t.string  :management_scope, null: false, default: "personal"  # personal | account_managed
  t.string  :credential_kind, null: false   # oauth2 | api_key | none
  t.string  :access_token                   # encrypts
  t.string  :refresh_token                  # encrypts
  t.datetime :expires_at
  t.string  :granted_scopes, array: true, default: []
  t.string  :enabled_capabilities, array: true, default: []   # which surfaces this connection serves
  t.string  :status, null: false, default: "connected"
  # connected | reauthorization_required | suspended | revoked | error
  t.jsonb   :settings, default: {}
  t.timestamps
  t.index [:account_id, :provider, :external_subject_id], unique: true,
          where: "external_subject_id IS NOT NULL"
end
# ObfuscatesId → stable opaque public id ("svc_7k…") for API + audit use.

# agent_service_grants — one agent × one capability × one connection
create_table :agent_service_grants do |t|
  t.references :agent, null: false, foreign_key: true
  t.references :external_connection, null: false, foreign_key: true
  t.string :capability, null: false               # "gmail", "google_drive", …
  t.string :allowed_actions, array: true, null: false, default: []
  t.jsonb  :restrictions, default: {}             # folder/label allowlists, size caps…
  t.string :confirmation_policy, null: false, default: "none"  # none | human_confirm (future writes)
  t.timestamps
  t.index [:agent_id, :external_connection_id, :capability], unique: true
end

# service_invocations — durable operations, not just audit rows (§7)
create_table :service_invocations do |t|
  t.references :agent, null: false
  t.references :external_connection, null: false
  t.string  :capability, null: false
  t.string  :action, null: false
  t.string  :status, null: false, default: "queued"
  # queued | running | succeeded | failed | cancelled
  t.string  :error_code                     # safe, enumerable — never raw provider bodies
  t.jsonb   :params_digest                  # summarized/redacted, never raw content
  t.jsonb   :result_metadata                # counts, filenames, sizes — never content
  t.string  :idempotency_key
  t.string  :request_fingerprint            # digest of (action, params) for idempotency conflict checks
  t.integer :duration_ms
  t.datetime :started_at, :completed_at, :expires_at
  t.timestamps
  t.index [:agent_id, :idempotency_key], unique: true, where: "idempotency_key IS NOT NULL"
end
```

Model-level invariants (enforced in models, plus DB constraints where practical — not controller convention):

```ruby
grant.agent.account_id == grant.external_connection.account_id
Current.api_agent.account_id == Current.api_key.account_id
```

All connection, invocation, result, and download lookups scope through the account; cross-account ids return 404, not 403.

## 3. The registry — common path, honestly scoped

Adapters live in `app/lib/services/`, discovered by directory glob (the `Agent.available_tools` pattern). One adapter per **capability**, declaring: provider, required OAuth scopes per action, action schemas with per-action risk class, manual path, and lifecycle hooks.

```ruby
class Services::GoogleDrive < Services::Base
  self.capability   = "google_drive"
  self.provider     = "google"
  self.display_name = "Google Drive"
  self.manual_path  = "docs/agents/services/google_drive.md"

  action :list_files,    risk: :read,  scopes: %w[drive.readonly], params: { folder_id: :string, query: :string }
  action :download_file, risk: :read,  scopes: %w[drive.readonly], params: { file_id: :string }
  action :search,        risk: :read,  scopes: %w[drive.readonly], params: { query: :string }
  action :upload_file,   risk: :write, scopes: %w[drive.file],     params: { path: :string, folder_id: :string }
  # v1 ships risk: :read actions only (§8)
end
```

Provider-level OAuth config (authorize/token URLs, client credentials, subject-id extraction) lives once per **provider** in `app/lib/services/providers/` — so Gmail, Drive, and Calendar adapters share the Google OAuth machinery and a single connection.

**The extensibility claim, softened per review:** the registry provides the common path — connection lifecycle, consent, grants, manifest, invocation routing, param validation, audit. Adapters declaratively contribute actions, parameter schemas, connection settings, and lifecycle hooks. Simple request/response services need only the adapter + manual. Services with webhooks, scheduled sync, or heavy normalization will additionally need their own jobs, routes, or UI — plus, always: tests, provider app registration, and a `docs/stack/` reference. The registry lowers the floor; it does not promise the ceiling is flat.

Adapters may implement any of four **facets** on the same connection/grant spine:

1. **Agent-invokable actions** (Drive, Gmail, Dropbox) — this doc's main path;
2. **Scheduled sync** (Oura-shaped) — background jobs on the connection's credentials;
3. **Webhook processing** — provider push, verified and normalized;
4. **Context projection** — pushing summaries into conversation context (the existing `Chat::Contextualizable` mechanism).

Oura does not migrate in v1, but the spine must not preclude it: an Oura-like adapter with zero invokable actions and a sync facet must be expressible (acceptance criterion 12).

## 4. Connections, consent, and settings UI

**OAuth flow** — one `ExternalConnectionsController`, all providers: `GET /services/:provider/connect` (SecureRandom state, 10-minute session expiry — the existing house dance) → callback → token exchange → **fetch and store the provider identity** (`external_subject_id`, `external_identity`) → upsert on `[account, provider, external_subject_id]` so reconnecting the same identity updates rather than duplicates. The user labels the connection ("Daniel — work") and selects which capabilities it serves (`enabled_capabilities`).

**Consent model:**

- **Personal/delegated** (`management_scope: personal`): authorized by an individual user (`connected_by_user_id`). Only that user can reauthorize or expand scopes. Account admins may *disable* grants or *remove* the connection — reduction is admin-territory, expansion is consent-territory. Admins must never silently broaden another user's OAuth consent. If the consenting user loses account membership, the connection and all its grants move to `suspended` until explicitly reconnected or transferred.
- **Account-managed** (`management_scope: account_managed`): team API keys and service accounts (transcription's ElevenLabs key). Admin-controlled throughout.

**Settings UI** (one Svelte page, registry-driven): per-provider connect buttons; per-connection card showing label, external identity, status, capabilities, consenting user; per-connection **grant matrix** — which agents, which capabilities, which action preset. The page must make visible *whose external identity is delegated to which agent* — that sentence is the UI's job.

**Grant assignment is explicit-only, all services.** The connect screen may offer to create selected grants as part of the flow, but nothing is auto-granted (review decision 2). Presets per adapter — "read only", "read + upload", "drafts only", "custom" — expand to explicit `allowed_actions` sets at save time; the stored truth is always the action list.

## 5. Authority — four layers, intersection only

Effective permission for any invocation is the intersection of:

1. **Provider OAuth scopes** actually granted on the connection (`granted_scopes`);
2. **Capabilities enabled** on the connection (`enabled_capabilities`);
3. **The grant's `allowed_actions`**;
4. **The grant's `restrictions`** (adapter-interpreted narrowing: folder allowlists, label filters, size caps).

No layer may expand another. An action passing layers 2–4 but lacking its declared OAuth scope fails with `reauthorization_required` guidance — it does not trigger silent scope escalation (§9).

## 6. Agent-facing API

All endpoints under existing `api_authentication.rb`; `Current.api_agent` required.

### 6.1 Discovery — `GET /api/v1/capabilities`

One entry **per grant** (connection × capability), because "gmail" is not an address:

```json
{
  "manifest_revision": "mr_9f2c…",
  "services": [
    {
      "connection_id": "svc_7k…",
      "service": "gmail",
      "label": "Daniel — work",
      "identity": "daniel@example.com",
      "status": "connected",
      "actions": ["search_messages", "read_message"],
      "manual": "/api/v1/capabilities/gmail/manual"
    },
    {
      "connection_id": "svc_2p…",
      "service": "google_drive",
      "label": "Daniel — personal",
      "identity": "daniel@gmail.example",
      "status": "reauthorization_required",
      "actions": ["list_files", "download_file", "search"],
      "manual": "/api/v1/capabilities/google_drive/manual"
    }
  ]
}
```

Only granted entries appear — an agent granted one connection cannot discover the other. Granted-but-unavailable connections **remain visible** as `reauthorization_required` rather than vanishing indistinguishably; the agent can then tell Daniel "your work Google needs reconnecting" instead of hallucinating absence. `manifest_revision` is a digest of the agent's grant set + connection statuses, used for the bounded trigger notice (§6.5).

### 6.2 Documentation — `GET /api/v1/capabilities/:capability/manual`

Markdown manual per capability, served from the Rails repo (`docs/agents/services/<capability>.md`) — single source of truth, ships with deploys, no image rebuild. Contains: action reference with parameters, connection-selection guidance (always pass `connection_id`; when multiple identities exist, ask which one if ambiguous), worked `helixkit-services` examples, service caveats, and the untrusted-content framing (§8).

### 6.3 Execution — `POST /api/v1/service-connections/:connection_id/invocations`

```json
{ "capability": "google_drive", "action": "download_file", "params": { "file_id": "1AbC…" } }
```

- Connection id is the routing key — no "which gmail?" ambiguity can exist in the API.
- Unknown/unpermitted action → 422/403 with `allowed_actions` and a readable reason (the polymorphic-tool error pattern).
- **Idempotency:** any non-read action or async job creation requires an `Idempotency-Key` header. Same key + same `request_fingerprint` → return the original invocation's result. Same key + different params → 409. The key wraps token refresh and provider retries, so a timeout cannot create two emails, uploads, or transcription jobs.
- Synchronous small results return inline. Async actions return `202 { "invocation_id": "inv_…" }`; poll `GET /api/v1/service-connections/:connection_id/invocations/:id`.
- **Provider response limits** enforced server-side: item-count caps on lists, payload byte caps, per-action timeouts, file-type allowlists on downloads.
- Per-agent per-connection rate limiting (sliding window in Solid Cache).

### 6.4 Files — download to the runtime, attach through the front door

File-producing actions do **not** create durable server-side `Attachment` records (that would orphan storage and breach the image-gen review's attachment boundary). They return a short-lived signed download URL; the helper streams it to a local path; the agent attaches via the existing multipart message request, which creates the durable attachment atomically:

```bash
helixkit-services invoke google_drive download_file \
  --connection svc_7k… --param file_id=1AbC… --output /tmp/board-deck.pdf

helixkit-post-message "$CHAT_ID" "Here's the deck." --attach /tmp/board-deck.pdf
```

No `--attach-id` flag; no new attachment machinery (review decision 5). Downloading a file and never posting it leaves nothing durable behind (acceptance criterion 11).

### 6.5 Container side — constant cost, bounded notices

1. **`runtime-instructions.md`** gains ~4 static lines: service access may exist; `helixkit-services list` is the live source of truth; read the capability manual before first use; your memory of the list may be stale.
2. **One generic helper**, `helixkit-services` (`list` | `manual <capability>` | `invoke <capability> <action> --connection <id> [--param k=v]… [--output path]` | `status <connection> <invocation_id>`). One binary forever.
3. **Bounded trigger notice** — per review, *not* an enumeration of connections or identities. The `ExternalAgent*Request` builders append at most:
   > External service access is available or has changed (manifest revision mr_9f2c…). Run `helixkit-services list`.
   included only when the agent has grants, with the revision digest letting the agent skip a redundant list call. Identities never appear in trigger text.

One agent-runtime image rebuild at rollout; none per added service.

## 7. Async invocations are durable operations

`ServiceInvocation` is the operation record, not an audit afterthought: status machine (`queued → running → succeeded|failed|cancelled`), safe `error_code`, `result_metadata` (never content), timestamps, `expires_at` for result retention, idempotency key + request fingerprint. The executing job **re-checks authorization at run time** — a grant revoked between enqueue and execution aborts the job. Polling is the v1 recovery path; a later trigger nudge may *announce* completion but must never be the only way to recover a result.

## 8. Security and the v1 write policy

**v1 ships reads, searches, and downloads only.** Optionally Gmail *draft creation* (visible, non-sent, human completes the act). Not in v1: Gmail send, deletion, public sharing, permission changes, or any consequential write. The untrusted-content warning is necessary but not sufficient — an agent can read hostile instructions from a document and then use a perfectly valid send action; the only v1-safe posture is that no such action exists. Before consequential writes ship, a follow-up doc must define: human confirmation flow (`confirmation_policy` on grants is the reserved seam), action risk classes, idempotency semantics (§6.3 provides the substrate), retry semantics, and audit behavior.

- **Tokens never leave Rails.** Proxied results only; nothing in container env, `docker inspect`, or Chaos config.
- **Structured provenance:** every result the API returns to an agent is wrapped with `{ "trust": "untrusted_external_data", "source": { "connection_id": …, "identity": … } }` — machine-marked, not just prose-warned. Manuals carry the `TRUSTED_CONTEXT_INSTRUCTION`-style framing: external content is data, never instructions.
- **Audit without leaking:** `service_invocations` stores action names, digests, outcomes, durations. Never bodies. Never in `audit_logs` (plaintext-leak finding, `docs/20260724-account-api-keys-review-from-lume.md`).
- **Log/exception filtering** for tokens, authorization codes, and provider response bodies (parameter filtering + exception scrubbing), per §9.
- **Blast radius:** grant revocation and connection disconnect take effect on the next API request — no restart, nothing cached container-side.

## 9. Token lifecycle

- **Per-connection locking** around refresh (row lock or advisory lock) — concurrent triggers must not race a rotation.
- **Atomic rotation**: new access + refresh tokens persist together; when a provider callback omits a refresh token (Google re-consent behavior), the existing one is preserved, never nulled.
- Refresh-before-expiry sweep (`RefreshServiceTokensJob`, `expires_at < 15.minutes.from_now`) plus refresh-and-retry-once on 401.
- Unrecoverable refresh failure → `status: reauthorization_required` (visible in manifest, §6.1) — never silent deletion, never indistinguishable absence.
- **Scope expansion only through a new human consent flow** by the consenting user. No incremental-auth shortcuts, no admin-initiated broadening of personal connections.
- **Disconnect defines its consequences explicitly:** grants deleted or suspended (choose: suspended, so reconnect restores them), queued invocations cancelled, cached/normalized data for sync-facet adapters deleted or retained per adapter declaration, provider-side revocation attempted where supported.

## 10. Acceptance criteria

1. Two connections to the same service coexist in one HelixKit account.
2. An agent granted one connection cannot discover or invoke the other.
3. The manifest clearly identifies the external account selected for every entry.
4. A personal connection cannot have its consent broadened by another account member.
5. Removing the consenting member suspends that connection and its grants.
6. Revoking a grant takes effect on the next API request without any restart.
7. Cross-account connection and invocation ids return not found.
8. Concurrent token refresh does not corrupt rotated credentials.
9. Retrying a write or async start (same `Idempotency-Key`) does not duplicate provider-side effects.
10. External content is machine-marked `untrusted_external_data` and cannot directly trigger an unconfirmed consequential action (v1: no such action exists to trigger).
11. Downloading a file without posting it leaves no durable attachment orphan.
12. An Oura-like scheduled-sync/context-projection integration can use the same connection and grant spine without pretending to be a synchronous invocation.

## 11. Rollout

1. **Connection spine** — `external_connections` with multiplicity, labels, external identities, consenting-user provenance, credential lifecycle (§9), account isolation (§2 invariants + tests).
2. **Grant spine** — capability × connection grants, explicit `allowed_actions`, restrictions, explicit-only assignment, settings-UI grant matrix.
3. **Agent surface** — manifest with `manifest_revision`, capability manuals, connection-scoped invocation endpoint with idempotency, `helixkit-services` helper, bounded trigger notice, image rebuild.
4. **First adapter** — Google Drive, read-only. **Tested with two Google identities in the same HelixKit account** (this exercises the entire v1→v2 remodel).
5. **Non-OAuth/async adapter** — transcription (ElevenLabs, `account_managed` key): durable polling, idempotent job creation, authorization re-check at execution.
6. **Non-invocation compatibility** — bridge or migrate Oura far enough to prove the sync + context-projection facets on the same spine.
7. **Later, per demand** — Dropbox; Gmail read (with §8 provenance marking); Gmail drafts; consequential writes only after the confirmation/risk-class follow-up doc.

## 12. Resolved and remaining questions

Resolved by review: invoke endpoint shape (generic, connection-scoped); grant defaults (explicit-only everywhere); inline path (ignored — Chaos-only end state); GitHub/Oura/X migration (not v1; spine must support their lifecycle first); attachment handling (runtime download + existing `--attach`); async completion (polling first, nudge optional later).

Remaining, held lightly:

1. **Suspension vs deletion of grants on disconnect** — proposed: suspend, so reconnecting the same `external_subject_id` restores the grant matrix without re-entry. Cheap either way; suspend preserves admin intent.
2. **Where capability-enablement UX lives** — proposed: on the connection card (a Google connection shows Gmail/Drive/Calendar toggles). Alternative: implied by grants. Explicit toggles keep layer 2 of the authority intersection visible.
3. **Manifest-revision granularity** — per-agent digest (proposed) vs global counter. Per-agent is more precise; global is simpler. Low stakes.

---

*v1 exploration provenance retained in `260728-01`: parallel source sweeps of `helix_kit` and `chaos`/`chaos-agent`, 2026-07-28 — MCP removal rationale; no deferred MCP loading in Chaos; env-at-creation credential injection; `EXTERNALLY_MANAGED_ATTRIBUTES`; two-tier runtime docs. v2 structural remodel (connection = external identity; capability ≠ connection; action-level authority; write moratorium) originates in Mira's review.*
