# Agent service integrations — direct credentials, scoped consent, and optional inbound bridges

**Date:** 2026-08-08
**Author:** Daniel / Mira collaboration (final v5)
**Status:** Accepted requirement — ready for implementation
**Supersedes:** `260728-01d-agent-service-integrations.md`
**Reviews integrated:** `260728-01d-agent-service-integrations-review-from-lume.md`
**Related:** `260524-02-helixkit-hosted-agents-v2.md`, `260725-02a-runtime-managed-agent-documentation.md`

---

## 1. Architecture in one sentence

> souls.house obtains and stores external-service credentials with human consent,
> provisions selected credentials and concise access instructions into selected
> resident runtimes, and otherwise lets residents use provider APIs and SDKs
> directly; the platform implements provider behavior only where an inbound
> endpoint or platform-owned lifecycle is genuinely required.

The ordinary outbound path is:

```text
resident → provider API
```

not:

```text
resident → souls.house operation wrapper → provider API
```

## 2. Responsibility boundary

### souls.house owns

- Human-facing OAuth and API-key setup.
- Personal versus account-managed credential ownership.
- Recording the external identity represented by a credential.
- Selecting which residents receive each credential.
- Default-on/default-off behavior for newly created residents.
- Scope-selection UX at authorization time.
- Encryption at rest and safe runtime materialization.
- Credential rotation, revocation, and reconciliation.
- Concise provider metadata: identity, granted scopes, API origins,
  documentation URLs, credential strategy, and warnings.
- Narrow token refresh brokerage where application-wide confidential client
  secrets must not be distributed.
- Optional inbound webhook receipt, verification, deduplication, routing, and
  delivery.

### The resident owns

- Reading provider documentation.
- Choosing an SDK, CLI, HTTP client, or local helper.
- Understanding provider endpoints and response formats.
- Direct API reads and writes within the credential's provider-enforced scopes.
- Provider-specific retries, pagination, idempotency, and workflow logic.
- Recording reusable knowledge and scripts in resident-owned work space.

### souls.house does not own

- A catalogue of provider operations.
- Per-operation parameter schemas.
- A generic service-invocation resource.
- Wrapping or reshaping provider responses.
- Duplicating provider SDKs or manuals.
- Pretending to enforce restrictions narrower than the credential itself.

## 3. Trust and policy model

The credential is the authority. Enabling a connection for a resident gives the
resident its full practical authority.

The provider-enforced OAuth scope set or API-key privilege set is therefore the
real policy model. Scope-selection UX is security-critical, not decorative.

For content-bearing services such as Dropbox, Drive, and email:

- the default authorization profile is read-only;
- write-capable profiles are deliberate, clearly labelled choices;
- the UI explains that narrower scopes reduce both ordinary mistakes and
  prompt-injection-induced misuse;
- connection cards display actual granted scopes, never merely the profile name
  selected before authorization.

Named access profiles are authorization-time sugar only. For example:

```text
Dropbox:
- Read only
- Read and write
- Full file and sharing management
```

Profiles expand to exact requested provider scopes. The persisted connection
stores the actual scopes returned by the provider.

If different residents need materially different authority, users create
separate provider authorizations with different scopes or separate provider
credentials.

## 4. Core data model

```ruby
# service_authorization_attempts — durable account-bound OAuth state
create_table :service_authorization_attempts do |t|
  t.references :account, null: false, foreign_key: true
  t.references :user, null: false, foreign_key: true
  t.string :provider, null: false
  t.string :management_scope, null: false
  t.string :access_profile, null: false
  t.jsonb :requested_scopes, null: false, default: []
  t.string :state_digest, null: false
  t.text :pkce_verifier
  t.string :return_path
  t.datetime :expires_at, null: false
  t.datetime :consumed_at
  t.timestamps
end

# service_connections — one credentialed external identity
create_table :service_connections do |t|
  t.references :account, null: false, foreign_key: true
  t.references :connected_by_user, null: false,
               foreign_key: { to_table: :users }
  t.references :legacy_oura_integration, foreign_key: { to_table: :oura_integrations }

  t.string :provider, null: false
  t.string :external_subject_id
  t.string :external_identity
  t.string :label
  t.string :management_scope, null: false, default: "personal"
  t.string :credential_kind, null: false
  t.text :credential_payload
  t.jsonb :credential_metadata, null: false, default: {}
  t.string :status, null: false, default: "connected"
  t.boolean :enabled_for_new_agents, null: false, default: false
  t.boolean :freely_provisionable, null: false, default: false
  t.integer :credential_revision, null: false, default: 1
  t.timestamps
end

# agent_service_accesses — whether a connection is provisioned to a resident
create_table :agent_service_accesses do |t|
  t.references :agent, null: false, foreign_key: true
  t.references :service_connection, null: false, foreign_key: true
  t.boolean :enabled, null: false, default: true
  t.boolean :follows_default, null: false, default: false
  t.integer :provisioned_revision
  t.datetime :provisioned_at
  t.string :provisioning_status
  t.string :provisioning_error_code
  t.timestamps
end
```

`credential_payload` is encrypted structured data. Provider credentials are not
uniform, and must not be forced into misleading OAuth-only columns.

An adopted legacy Oura connection may reference its existing
`oura_integrations` row instead of copying or moving encrypted tokens. The old
row remains the token source of truth until a separately reviewed migration
retires it.

## 5. Lightweight service definitions

A service definition describes authentication and runtime discovery, not
provider operations:

```ruby
Services::Definition.register(
  key: "dropbox",
  name: "Dropbox",
  management_scopes: %w[personal account_managed],
  credential_strategy: "self_refreshing",
  api_origins: %w[
    https://api.dropboxapi.com
    https://content.dropboxapi.com
  ],
  documentation: [
    "https://www.dropbox.com/developers/documentation/http/documentation"
  ],
  access_profiles: {
    "read_only" => [...],
    "read_write" => [...],
    "full_sharing" => [...]
  },
  default_access_profile: "read_only"
)
```

Provider-specific code is permitted for OAuth URL construction, token exchange,
identity lookup, payload validation/rendering, refresh/revocation differences,
and inbound behavior. It is not permitted merely to wrap provider endpoints.

## 6. Authorization, identity, and consent

OAuth initiation is durable and account-bound:

```text
POST /accounts/:account_id/service_authorizations
GET  /service_authorizations/callback
```

A high-entropy state resolves an attempt containing account, user, provider,
management scope, chosen access profile, exact requested scopes, PKCE verifier,
return path, expiry, and consumption state.

Callback parameters never choose the account, user, provider, or credential
owner.

A connection represents an external identity:

- Daniel's personal Dropbox;
- a shared account-managed Dropbox;
- Daniel's Oura account;
- Paulina's Oura account.

Multiple identities for one provider may coexist in one account.

### Personal connections

- Only the consenting user may authorize, reauthorize, rotate, or expand scopes.
- First-time provisioning to each resident requires that user's action.
- Administrators may reduce or remove access but cannot broaden consent.
- The owner may explicitly mark a connection freely provisionable within the
  account; this is visible and defaults off.
- Removing the user from the account suspends the connection and removes it from
  resident runtimes.

### Account-managed connections

- Account administrators authorize or enter the credential.
- `connected_by_user_id` records who performed the setup.
- Administrators may provision the connection to residents.

## 7. Credential strategies

Service definitions select exactly one:

- `static`: API key, PAT, long-lived token, or service-account bundle.
- `self_refreshing`: the runtime receives the refresh material required to stay
  independent. Routine access-token refresh does not recreate the container or
  involve souls.house.
- `refresh_broker`: souls.house keeps an application-wide confidential secret
  and exposes only a narrow, resident-authenticated access-token endpoint. It
  never proxies provider operations.

The strategy is visible in the runtime manifest so the resident knows the
correct procedure.

## 8. Runtime materialization

Credentials and provider instructions are hosting context, not identity. They
must never be written into:

```text
/home/agent/identity
/home/agent/repo
/home/agent/work
```

The resident-facing contract is:

```text
/run/helixkit/services.yml
```

The path is on container tmpfs, created at startup, readable only by the resident
runtime user, and absent from persistent volumes and backups.

Illustrative shape:

```yaml
services:
  - connection_id: svc_abc123
    provider: dropbox
    identity: daniel@example.com
    label: Daniel — personal
    credential_revision: 4
    credential_strategy: self_refreshing
    credentials:
      access_token: ...
      refresh_token: ...
      expires_at: 2026-08-08T20:00:00Z
      client_id: ...
      token_url: https://api.dropboxapi.com/oauth2/token
    access:
      scopes: [...]
      api_origins: [...]
    documentation: [...]
```

The runtime guide says the manifest is runtime-supplied, is live truth, and
contains untrusted external-service authority that must be handled carefully.

Connection, rotation, grant, disable, and disconnect changes schedule safe
container recreation after an active turn finishes. Only changes to refresh
material or authority increment the credential revision; ordinary self-refresh
does not.

## 9. Revocation and audit

Disabling access removes managed runtime material on reconciliation, starts a
fresh session without it, and attempts provider revocation when appropriate.
The product does not claim cryptographic erasure of copies a resident may
already have made.

For stronger isolation, users may create one provider authorization per
resident.

souls.house audits control-plane events only: connection lifecycle, consent,
scope changes, per-resident access changes, manifest revisions, reconciliation,
inbound delivery, and refresh-broker issuance. Direct provider operations are
audited by provider and runtime logs, not falsely claimed by Rails.

Secrets, codes, tokens, keys, and provider response bodies never enter ordinary
logs or audit metadata.

## 10. Inbound integrations and platform consumers

Inbound webhooks are the main reason souls.house may stand in the data path.
Inbound adapters may own stable public routes, signature verification,
deduplication, account/connection lookup, subscription lifecycle, and resident
routing.

Inbound behavior never forces the corresponding outbound API through
souls.house.

Oura's existing scheduled health-context synchronization remains a separate
platform consumer of the same external identity. Direct resident access and
platform context projection may coexist.

## 11. Existing Oura preservation and transition

The transition must not wipe, replace, copy, or invalidate working Oura
credentials.

1. Existing `oura_integrations` rows remain untouched.
2. Existing OAuth callback, refresh, sync, and context behavior remains available
   until the replacement path is proven.
3. Adoption creates an account-scoped `service_connection` that references the
   legacy row; it does not duplicate encrypted token material.
4. The legacy row remains the sole refresh writer during compatibility mode.
5. A user chooses one account to adopt an existing Oura identity into.
6. Additional accounts require fresh Oura authorization and independent token
   lineages.
7. Disconnecting or deleting the service connection does not revoke or clear the
   legacy Oura row unless the user explicitly chooses the destructive
   disconnect action.
8. Migration tests compare token ciphertext and functional connectivity before
   and after adoption.

## 12. User experience

### Account services

Lists service types supporting account-managed credentials and their connected
identities. Administrators can connect, label, inspect scopes, set the new-
resident default, choose residents, rotate, and disconnect.

Dropbox appears here.

### Personal services

Lists the current user's service identities, honest authority summaries, default
behavior, and receiving residents. Dropbox and Oura appear here.

### Resident integrations tab

Lists available account and personal connections. A toggle means:

> Provision this connection's credential to this resident.

It does not imply per-operation Rails enforcement.

## 13. Acceptance criteria

1. Multiple Dropbox identities coexist in one account.
2. Personal and account-managed Dropbox connections are both supported.
3. A personal connection reaches only explicitly authorized residents.
4. A resident calls Dropbox and Oura directly without provider-operation Rails
   endpoints.
5. Named scope profiles default Dropbox to read-only and display actual granted
   scopes after authorization.
6. Runtime credentials exist only at `/run/helixkit/services.yml` on tmpfs.
7. Secrets never appear in identity, repo, work, prompts, Inertia props, audit
   metadata, or ordinary logs.
8. A self-refreshing resident refreshes a Dropbox token without container
   recreation or souls.house interaction.
9. Removing access recreates the runtime without that connection and reports
   failures.
10. Cross-account access is impossible through associations and callback state.
11. Existing working Oura credentials remain byte-for-byte untouched by
    adoption.
12. Existing Oura sync and health-context projection continue to work after
    adoption.
13. A legacy Oura credential is never copied into two account-scoped rows.
14. Dropbox file creation and sharing can be learned from Dropbox's documentation
    and executed without new Rails operation code.

## 14. First proof

1. Connect a disposable personal Dropbox using the read/write/sharing profile.
2. Provision it to one test resident.
3. Give the resident no Dropbox helper or souls.house operation manual.
4. Ask it to inspect the manifest and provider documentation.
5. Create a folder, upload a file, list it, and create a shared link.
6. Refresh its own access token.
7. Disable the connection and reconcile the runtime.
8. Verify the credential disappears and another resident never received it.

The proof fails if Dropbox operations require provider-specific Rails code.
