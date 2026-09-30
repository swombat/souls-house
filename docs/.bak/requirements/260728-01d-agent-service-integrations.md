# Agent service integrations — direct credentials, agent autonomy, and optional inbound bridges

**Date:** 2026-07-31
**Author:** Daniel / Mira collaboration (draft v4 for Lume review)
**Status:** Requirement / fresh redesign after implementation rollback
**Supersedes:** `260728-01c-agent-service-integrations.md`
**Related:** `260524-02-helixkit-hosted-agents-v2.md`, `260725-02a-runtime-managed-agent-documentation.md`

---

## 0. Why this is a fresh redesign

The v3 requirement and its first implementation made HelixKit a mediated service
API:

```text
agent → HelixKit capability/action endpoint → provider API
```

That preserved credentials, policy enforcement, and per-operation audit inside
Rails, but it recreated the exact bottleneck the integration framework was meant
to remove. Every Dropbox operation, Gmail operation, calendar operation, Oura
query, and future service feature would require:

- a HelixKit action declaration;
- parameters and validation;
- provider-specific invocation code;
- result shaping and limits;
- agent documentation for the HelixKit wrapper;
- tests for behavior already implemented and documented by the provider.

Adding a service would remain a HelixKit development project rather than
something an autonomous agent could learn and use.

The implementation built from v3 was therefore rolled back on 2026-07-31 before
shipping. This document retains the useful ownership and consent findings from
the earlier drafts, but replaces the invocation architecture completely.

## 1. Architecture in one sentence

> HelixKit obtains and stores external-service credentials with human consent,
> provisions selected credentials and concise access instructions into selected
> agent runtimes, and otherwise lets agents use provider APIs and SDKs directly;
> HelixKit implements provider behavior only where a stable inbound endpoint or
> platform-owned lifecycle is genuinely required.

The ordinary outbound path is:

```text
agent → provider API
```

not:

```text
agent → HelixKit's reimplementation of provider API → provider API
```

## 2. Boundary of responsibility

### 2.1 HelixKit owns

- Human-facing OAuth and API-key setup.
- Personal versus account-managed credential ownership.
- Recording which external identity a credential represents.
- Selecting which agents receive that credential.
- Default-on/default-off behavior for newly created agents.
- Encryption at rest before runtime provisioning.
- Creating, updating, and removing runtime-managed secret material.
- Concise provider metadata: identity, scopes, API origins, documentation URLs,
  credential location, refresh instructions, and relevant warnings.
- Credential refresh or rotation only where the agent cannot safely perform it
  itself.
- Provider revocation attempts when a connection is disconnected.
- Optional inbound bridges: webhook receipt, signature verification, account and
  agent routing, deduplication, and delivery.

### 2.2 The agent owns

- Reading provider documentation.
- Choosing an SDK, CLI, HTTP client, or writing a helper.
- Understanding provider endpoints and response formats.
- Deciding how to accomplish a user request.
- Direct API reads and writes within the authority of the supplied credential.
- Provider-specific retries, pagination, idempotency, and workflow logic.
- Recording reusable knowledge or scripts in agent-owned working space where
  appropriate.

### 2.3 HelixKit explicitly does not own

- A catalogue of provider API operations.
- Per-operation parameter schemas.
- A generic `ServiceInvocation` resource.
- Wrapping or reshaping provider responses.
- Downloading provider files merely to hand them back to the agent.
- Duplicating provider SDKs.
- Maintaining a second manual for the provider API.
- Pretending it can enforce per-action restrictions after handing the agent a
  bearer credential.

## 3. Trust model: the credential is the authority

Direct credential access changes the policy model honestly:

- A connection's granted OAuth scopes or API-key privileges define its authority.
- Enabling a connection for an agent gives that agent the connection's full
  practical authority.
- HelixKit cannot reliably grant one agent `read_file` and another
  `create_shared_link` while giving both the same unrestricted Dropbox token.
- If materially different authority is required, create separate provider
  authorizations with different scopes, separate API keys, or use a future
  provider-native delegation mechanism.

The UI must therefore avoid false precision. It should say:

> This agent will receive credentials for Daniel's Dropbox with file and sharing
> management access.

It must not imply HelixKit can enforce an action checklist that the credential
itself does not enforce.

Trust in the agent is intentional. Protection from accidental disclosure remains
important, but is not the same as withholding usable authority from the agent.

## 4. Core data model

Names are illustrative; the important part is the separation of connections
from per-agent provisioning.

```ruby
# service_connections — one credentialed external identity
create_table :service_connections do |t|
  t.references :account, null: false, foreign_key: true
  t.references :connected_by_user, null: false,
               foreign_key: { to_table: :users }

  t.string :provider, null: false
  t.string :external_subject_id
  t.string :external_identity
  t.string :label

  t.string :management_scope, null: false, default: "personal"
  # personal | account_managed

  t.string :credential_kind, null: false
  # oauth2 | api_key | token | credential_bundle

  t.text :credential_payload, null: false
  # encrypted structured data; exact shape belongs to provider authentication,
  # not a lowest-common-denominator access_token/api_key schema

  t.jsonb :credential_metadata, null: false, default: {}
  # non-secret: scopes, expiry, documentation hints, API origins, auth strategy

  t.string :status, null: false, default: "connected"
  # connected | suspended | revoked | error

  t.boolean :enabled_for_new_agents, null: false, default: false
  t.integer :credential_revision, null: false, default: 1
  t.timestamps

  t.index [:account_id, :provider, :external_subject_id],
          unique: true,
          where: "external_subject_id IS NOT NULL"
end

# agent_service_accesses — whether a connection is provisioned to an agent
create_table :agent_service_accesses do |t|
  t.references :agent, null: false, foreign_key: true
  t.references :service_connection, null: false, foreign_key: true
  t.boolean :enabled, null: false, default: true
  t.boolean :follows_default, null: false, default: false
  t.integer :provisioned_revision
  t.datetime :provisioned_at
  t.string :provisioning_status
  # pending | provisioned | removal_pending | failed
  t.string :provisioning_error_code
  t.timestamps

  t.index [:agent_id, :service_connection_id], unique: true
end
```

### 4.1 Why an encrypted structured payload

Provider credentials are not uniform:

- API key only;
- access token and refresh token;
- token endpoint, client id, and PKCE metadata;
- service-account JSON;
- host, username, password, and certificate;
- several keys that must be used together.

Storing all of these as misleading OAuth columns recreates adapter assumptions.
The model validates the envelope and lets the authentication setup for each
provider validate its own payload shape.

## 5. Lightweight service definitions

Adding a service still requires enough information to establish credentials, but
not code for ordinary provider operations.

A service definition declares:

```yaml
key: dropbox
name: Dropbox
management_scopes: [personal, account_managed]
authentication:
  type: oauth2
  authorization_url: ...
  token_url: ...
  identity_url: ...
runtime:
  api_origins:
    - https://api.dropboxapi.com
    - https://content.dropboxapi.com
  documentation:
    - https://www.dropbox.com/developers/documentation/http/documentation
  credential_strategy: oauth_refresh_bundle
  notes:
    - Dropbox API v2 uses POST for many read operations.
inbound: false
```

Service-specific code is permitted for:

- OAuth URL and token exchange differences;
- fetching the authenticated identity;
- credential validation and rendering;
- refresh and revocation differences;
- webhook verification and routing, when inbound behavior exists.

It is not permitted merely to wrap provider endpoints the agent can call itself.

For API-key services, a declarative definition plus a credential-entry form may
be sufficient without any provider Ruby class.

## 6. Authorization and identity

### 6.1 Durable OAuth attempts remain useful

OAuth initiation should remain account-bound and durable:

```text
POST /accounts/:account_id/service_authorizations
GET  /service_authorizations/callback
```

The generic callback is shared by OAuth providers. A high-entropy `state`
resolves an authorization attempt that stores:

- account;
- user;
- provider;
- personal or account-managed ownership;
- requested provider scopes;
- PKCE verifier where applicable;
- return path;
- expiry and consumption state.

Callback parameters never choose the account, user, provider, or credential
owner.

### 6.2 Connection as external identity

The connection still represents an external identity, not a service in the
abstract:

- Daniel's personal Dropbox;
- GrantTree's shared Dropbox;
- Daniel's Oura account;
- Paulina's Oura account;
- a shared transcription API key.

Multiple identities for one provider may coexist in an account.

### 6.3 Consent and ownership

- **Personal:** only the consenting user may initially authorize, reconnect, or
  replace the credential. Account administrators may stop provisioning it to
  agents or remove it from the account, but may not silently assume the user's
  external identity.
- **Account-managed:** account administrators enter or authorize the credential.
  `connected_by_user_id` still records who performed the setup.
- Removing a consenting member suspends their personal connections and schedules
  secret removal from every agent runtime.
- Reconnecting an external subject as a different user requires an explicit
  transfer flow; credentials and provenance are never silently overwritten.

## 7. Runtime provisioning

### 7.1 Runtime-owned, not identity-owned

Credentials and provider instructions are hosting infrastructure. They must not
be written into:

```text
/home/agent/identity
```

or committed to the agent's repository.

Provision them through the existing encrypted runtime credential path, extended
with a `services` section, or through a new runtime-owned secret mount with
equivalent encryption and permissions.

Illustrative decrypted shape:

```yaml
services:
  - connection_id: svc_abc123
    provider: dropbox
    identity: daniel@example.com
    label: Daniel — personal
    credential_revision: 4
    credentials:
      access_token: ...
      refresh_token: ...
      expires_at: 2026-08-01T18:00:00Z
      client_id: ...
      token_url: https://api.dropboxapi.com/oauth2/token
    access:
      scopes:
        - files.metadata.read
        - files.metadata.write
        - files.content.read
        - files.content.write
        - sharing.read
        - sharing.write
      api_origins:
        - https://api.dropboxapi.com
        - https://content.dropboxapi.com
    documentation:
      - https://www.dropbox.com/developers/documentation/http/documentation
```

The concrete runtime path should be stable and discoverable, for example:

```text
/run/helixkit/services.yml
```

Permissions must restrict it to the agent runtime user.

### 7.2 Provisioning lifecycle

Connecting, rotating, granting, disabling, or disconnecting a service increments
the relevant credential revision and schedules reconciliation.

For v1, the existing safe container-recreation pattern is acceptable:

1. wait until no agent turn is active;
2. rebuild the encrypted credential payload;
3. recreate the sandbox;
4. verify the expected credential revision is present;
5. start a fresh Chaos session with a bounded “service access changed” notice.

Hot secret replacement may follow later, but must not be required for the first
correct version.

### 7.3 Agent discovery

The runtime guide should include only a small stable instruction:

> External service credentials may be available in the runtime-managed service
> manifest. Inspect it for identities, scopes, API origins, credential refresh
> instructions, and provider documentation. Provider APIs are used directly;
> HelixKit does not wrap their operations.

The manifest is live truth. Agent memory about available services may be stale.

## 8. Credential strategies

The credential definition declares one of a few lifecycle strategies.

### 8.1 Static credential

Examples: API key, PAT, long-lived token, service-account JSON.

The complete usable credential bundle is provisioned to the agent. Rotation
increments the connection revision and reconciles enabled runtimes.

### 8.2 Self-refreshing OAuth bundle

Where provider security permits it, provision everything needed for the agent to
refresh its own access token:

- access token;
- refresh token;
- expiry;
- token endpoint;
- client id;
- client secret only when deliberately acceptable;
- exact refresh instructions.

The agent then remains independent of HelixKit for outbound operation.

### 8.3 Narrow refresh broker

Some confidential OAuth clients should not disclose one application-wide client
secret to every agent. In that case HelixKit may expose a narrow endpoint:

```text
POST /api/v1/service-connections/:id/access-token
```

It:

- authenticates the agent;
- verifies that the connection is enabled for that agent;
- refreshes under a per-connection lock if necessary;
- returns the current short-lived access token and expiry;
- does not proxy, understand, or audit subsequent provider operations.

This is credential lifecycle, not a service API wrapper.

The provider definition must choose the strategy explicitly. HelixKit must not
silently give agents application-wide secrets as a shortcut.

## 9. Revocation has an honest limit

Once an autonomous agent has received a bearer credential, HelixKit cannot prove
that every copy has been erased. Disabling access must:

- remove the credential from the managed runtime on reconciliation;
- start a fresh session without the connection;
- revoke or rotate the provider credential where appropriate;
- clearly report provisioning/removal failures.

But the product must not claim next-request cryptographic revocation unless the
provider itself supports separate per-agent credentials or all access goes
through a broker.

For higher-assurance separation, users may create distinct provider credentials
per agent. That is a different security posture, not an invisible implementation
detail.

## 10. Inbound integrations

Inbound behavior is the main case where HelixKit genuinely must stand in the
data path.

Examples:

- Telegram webhook updates;
- inbound email push notifications;
- calendar or file-change webhooks;
- provider callbacks that must wake an agent;
- shared public endpoints where agent containers are not directly reachable.

An inbound adapter may implement:

- stable public route;
- provider signature verification;
- replay prevention and deduplication;
- connection/account lookup;
- subscription lifecycle;
- event normalization sufficient for safe delivery;
- routing to one or more enabled agents or conversations;
- bounded payload storage and retention.

Inbound adapters are optional extensions beside the credential connection. They
must not force the corresponding outbound API through HelixKit.

Telegram is therefore allowed to remain a substantial custom integration. Its
public webhook and conversation-routing responsibilities are real HelixKit work,
not duplicated outbound API behavior.

## 11. Scheduled work and context projection

Oura exposes another important boundary question.

The default model should be:

- provision Oura credentials and documentation to an enabled agent;
- let the agent query Oura directly when useful;
- let scheduled agent wakes perform periodic work if desired.

HelixKit should only retain a platform-owned Oura synchronization/context feature
if the product explicitly wants health context injected before the agent runs.
That feature is then a separate optional consumer of the same connection, not
the definition of service access and not a reason to wrap the Oura API generally.

## 12. User experience

### 12.1 Account settings

An **Account services** section lists service types that support account-managed
credentials and the connected identities. Administrators can:

- connect another identity;
- label it;
- inspect its authority/scopes;
- enable or disable it by default for new agents;
- choose enabled agents;
- rotate or disconnect it.

### 12.2 Personal settings

A **Personal services** section lists service types that support user-owned
credentials. Each member sees:

- their own connected identities and full management controls;
- other members' identities only to the degree needed to understand agent access,
  without seeing credentials;
- the agents currently receiving each identity;
- an honest summary of the authority being handed over.

Dropbox may appear in both sections. Oura appears only under personal services.

### 12.3 Agent integrations tab

The agent's Integrations tab lists available account and personal connections.
The toggle means:

> Provision this connection's credential to this agent.

It does not mean:

> Enable a HelixKit-written subset of provider API operations.

If the current user lacks authority to provision another user's personal
connection, enabling is unavailable. Administrators may reduce or remove access
but cannot broaden personal consent.

## 13. Audit

HelixKit audits control-plane events:

- connection created, reauthorized, rotated, suspended, or disconnected;
- consenting user and management scope;
- agent access enabled or disabled;
- credential revision provisioned or removed;
- inbound subscription and delivery events;
- refresh-broker token issuance, if that strategy is used.

HelixKit does not claim complete provider-operation audit when agents call
providers directly. Provider audit logs and agent runtime logs are the relevant
sources for those operations.

Secret values, authorization codes, refresh tokens, access tokens, API keys, and
credential payloads never enter audit metadata or ordinary logs.

## 14. Security requirements

- Credential payloads encrypted at rest in Rails.
- Runtime material written outside identity and repository volumes.
- Runtime files readable only by the agent user and required platform processes.
- No credentials injected into prompts or chat messages.
- No secrets returned through ordinary Inertia props or account JSON.
- OAuth state durable, expiring, one-time, and account-bound.
- PKCE used wherever supported.
- Personal consent cannot be broadened by account administration.
- Service definitions distinguish public metadata from secret payload fields.
- Log filtering covers authorization codes, tokens, API keys, client secrets,
  service-account JSON, and provider error bodies.
- Runtime recreation and backup behavior must not accidentally include plaintext
  service credentials in persistent agent backups.
- Agents receive an explicit warning that external content may be hostile and
  that credentials must not be pasted into untrusted pages or messages.

## 15. Acceptance criteria

1. Two Dropbox identities can coexist in one HelixKit account.
2. Daniel's personal Dropbox can be provisioned to one agent without being
   visible in another agent's runtime.
3. An account-managed connection may be provisioned to several agents.
4. Each enabled agent can call the provider API directly without a
   provider-operation endpoint in HelixKit.
5. Adding a new ordinary API-key service requires no HelixKit code for the
   provider's operations.
6. Adding a new OAuth service requires authentication/identity setup but no
   wrappers for ordinary API endpoints.
7. The runtime manifest clearly identifies provider, external identity, scopes,
   API origins, documentation, credential strategy, and credential revision.
8. Credentials never appear in identity files, repositories, prompts, Inertia
   props, or logs.
9. Removing an agent access record removes the managed runtime credential on
   reconciliation and reports any failure.
10. The UI does not claim per-action enforcement that direct credentials cannot
    provide.
11. A personal connection cannot be provisioned or reauthorized by another
    member without the consenting user's authority.
12. Removing a consenting member suspends the connection and schedules removal
    from all agent runtimes.
13. Concurrent OAuth flows for different accounts and providers do not overwrite
    one another.
14. A confidential OAuth provider can use the narrow refresh broker without
    routing provider operations through HelixKit.
15. An inbound service can verify and route webhooks without changing the direct
    outbound-access model.
16. Dropbox file creation or sharing can be learned and executed by the agent
    from Dropbox's own API documentation without new Rails application code.
17. Existing Oura behavior remains available until an explicit migration plan is
    accepted; this redesign does not silently move or destroy existing tokens.

## 16. Proposed first proof

Use Dropbox because it demonstrates the actual requirement:

1. Connect a personal Dropbox identity through HelixKit OAuth.
2. Request read, write, and sharing scopes chosen during setup.
3. Provision the credential and Dropbox documentation pointer into one test
   agent's runtime.
4. Give the agent no Dropbox-specific helper or HelixKit operation manual.
5. Ask it to inspect its available services, read Dropbox's documentation, create
   a folder, upload a small file, list it, and create a shared link.
6. Disable the connection for that agent and reconcile the runtime.
7. Verify the managed credential disappears.
8. Confirm another agent never received the identity or credential.

This test succeeds only if the agent can operate Dropbox without HelixKit
learning Dropbox's file API.

## 17. Questions for Lume

1. Should v1 extend the existing encrypted `credentials.yml.enc` and recreate
   containers on every service change, or introduce a separately mounted,
   hot-reloadable service-secret file now?
2. Is the three-strategy credential lifecycle (`static`, `self-refreshing OAuth`,
   `narrow refresh broker`) the right minimum, or can it be simplified without
   exposing application-wide client secrets?
3. Should connection authority be represented only by provider scopes, or do we
   need a small named access-profile concept solely for selecting OAuth scopes at
   authorization time?
4. Are account administrators allowed to provision another member's already
   authorized personal connection to an agent, or must the consenting user also
   approve each first-time agent provisioning?
5. Should provider documentation URLs live in Rails service definitions, the
   runtime image, or both?
6. What is the correct migration path for the existing user-global Oura model
   into account-scoped connections without duplicating refresh tokens across
   accounts?
7. Is “best-effort removal plus provider revocation” sufficiently explicit for
   the direct-credential trust model, or should high-assurance per-agent provider
   credentials be a first-class optional mode?

## 18. Rollout

1. Lume review and revision of this requirement.
2. Decide runtime secret materialization and OAuth refresh strategies.
3. Implement connection ownership and agent provisioning only.
4. Prove direct Dropbox management end to end with a disposable test identity.
5. Add settings and agent-tab UX.
6. Add service definitions for simple API-key/PAT services.
7. Treat inbound adapters as separate provider-specific projects.
8. Design and execute Oura migration only after the connection model is proven.

---

*Provenance: v1–v3 established the external-identity, ownership, durable OAuth,
and consent model. Daniel's review of the first implementation identified that
the action/capability/invocation layer recreated the tool-integration bottleneck.
The unshipped implementation was rolled back on 2026-07-31. This v4 keeps
HelixKit at the credential and inbound boundaries and restores provider API work
to the agent.*
