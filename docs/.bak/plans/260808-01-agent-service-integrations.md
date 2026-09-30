# Direct resident service integrations — implementation plan

**Date:** 2026-08-08
**Requirement:** `docs/requirements/260728-01e-agent-service-integrations.md`
**Status:** Implementation plan
**Starter services:** Dropbox and Oura

---

## 1. Goal

Build the smallest generic credential-and-consent spine that can:

- represent multiple external identities per account and provider;
- distinguish personal from account-managed credentials;
- authorize selected residents;
- materialize credentials and provider pointers at
  `/run/helixkit/services.yml`;
- let residents use provider APIs directly;
- preserve the existing working Oura integration without copying or replacing
  its encrypted tokens.

No provider operation wrappers or generic invocation API are introduced.

## 2. Existing seams

- Account authorization is association-scoped through
  `Current.user.confirmed_accounts`.
- Hosted residents are Docker containers created by `Agents::Sandbox`.
- Runtime recreation already waits for active turns through
  `AccountAgentCredentialsRefreshJob`.
- Runtime identity, repo, work, state, and Chaos homes are persistent Docker
  volumes.
- Runtime documentation is image-owned under `agent-runtime/docs`.
- Existing Oura credentials live encrypted on a user-global
  `OuraIntegration`; sync and prompt context depend on that model.

The new manifest must therefore be a sixth, non-persistent runtime surface, not
an extension of any resident-owned volume.

## 3. Database changes

Add:

- `service_authorization_attempts`;
- `service_connections`;
- `agent_service_accesses`.

All migrations are additive. No Oura column or row is altered.

`service_connections.legacy_oura_integration_id` is a compatibility reference.
For adopted legacy Oura connections, `credential_payload` remains nil and the
runtime renderer reads the credential bundle through the referenced model.

Uniqueness:

- authorization state digest globally unique;
- service connection external subject unique within account/provider when known;
- one service connection per adopted legacy Oura row and account;
- one access row per resident/connection.

## 4. Model layer

### `Services::Definition`

A small registry under `app/models/services/` defines public provider metadata:

- key/name;
- supported management scopes;
- credential strategy;
- OAuth endpoints and credentials location;
- API origins and documentation URLs;
- named access profiles and read-only default;
- callback adapter class.

Definitions contain no operation declarations.

### `ServiceAuthorizationAttempt`

Owns state generation/digest validation, expiry, one-time consumption, requested
scope immutability, and PKCE verifier encryption.

### `ServiceConnection`

Owns encrypted payload, identity/provenance, authority display, access defaults,
credential revision, runtime rendering, reconnect behavior, and disconnect
semantics.

Personal delegation checks live here:

- owner may add access;
- admins may remove access;
- `freely_provisionable` delegates addition to account administrators.

### `AgentServiceAccess`

Validates account equality, uniqueness, and provisioning state. Enabling or
disabling schedules safe runtime reconciliation.

## 5. OAuth flow

Routes:

```text
POST /accounts/:account_id/service_authorizations
GET  /service_authorizations/callback
```

Initiation:

1. association-scope the account;
2. validate provider, management scope, access profile, and actor authority;
3. persist exact scopes and PKCE verifier;
4. redirect to the provider.

Callback:

1. hash state and lock the attempt;
2. reject expired/consumed state;
3. recover all ownership/provider data from the attempt;
4. exchange code through the provider adapter;
5. fetch the external identity;
6. create or reconnect without silently changing provenance;
7. atomically consume the attempt;
8. redirect to the correct services page.

## 6. Runtime manifest

`Agents::ServiceManifest` renders only enabled, connected, authorized
connections for a resident.

`Agents::Sandbox#run_container!`:

1. render YAML to a host-side `Tempfile` with mode `0600`;
2. add Docker `--tmpfs /run/helixkit:rw,noexec,nosuid,nodev,mode=0700`;
3. bind the source file read-only to a staging path;
4. pass the staging path to the entrypoint;
5. entrypoint copies it into `/run/helixkit/services.yml`, sets owner/mode, and
   removes no persistent files;
6. the host tempfile is unlinked immediately after `docker run`.

The manifest is not supplied as an environment variable or command argument.
Tests assert secret values are absent from generated `docker inspect` env and
persistent mounts.

Runtime docs gain a short discovery and hostile-content warning.

## 7. Reconciliation

Extend `AccountAgentCredentialsRefreshJob` for service changes:

- wait while a turn is active;
- recreate the resident container;
- after successful start, mark each enabled access provisioned at the current
  revision;
- on failure retain the prior database authority state and record a safe error.

Creating a resident applies `enabled_for_new_agents` by creating explicit access
rows with `follows_default: true`.

Routine self-refresh inside the runtime does not update Rails or trigger
recreation.

## 8. Dropbox

Definition:

- personal and account-managed;
- OAuth 2 authorization-code with PKCE;
- self-refreshing credential strategy;
- read-only default;
- read/write and full-sharing opt-in profiles;
- identity lookup through Dropbox's current-account endpoint;
- API and content origins plus official HTTP documentation.

The payload includes access token, refresh token, expiry, client id, token URL,
and granted scopes. The application-wide client secret is not provisioned.

Disconnect attempts provider revocation before clearing the Rails payload.

No Dropbox file endpoint is implemented in Rails.

## 9. Oura compatibility-first integration

### Phase implemented here

- Keep `OuraIntegration`, its controller, token refresh, sync job, and health
  context operational.
- Add an adoption action that creates one personal account-scoped
  `ServiceConnection` referencing the existing row.
- Do not read or rewrite token columns during adoption.
- Render the runtime credential bundle from the referenced row at container
  creation.
- Keep the legacy row as the only refresh writer.
- Surface the adopted connection in Personal services and resident integrations.
- New Oura OAuth connections may use the generic flow only when no legacy row is
  being adopted.

### Explicitly deferred

- deleting `oura_integrations`;
- moving cached health data;
- copying a legacy token lineage to multiple accounts;
- replacing the existing sync/context consumer.

Tests capture encrypted database token values before adoption, perform adoption
and access changes, reload directly from the database, and assert equality.

## 10. Controllers and UX

Add:

- account services index;
- personal services index;
- connection update/disconnect;
- authorization create/callback;
- resident access update;
- Oura adoption.

Account settings links to Account services. User settings links to Personal
services. The resident edit Integrations tab receives serialized connection
cards and toggle permissions.

The UI:

- displays service types before connections;
- distinguishes personal/account-managed identities;
- defaults Dropbox authorization to read-only;
- describes write authority honestly;
- never receives secret payloads;
- keeps the old Oura route as a compatibility redirect into Personal services,
  not as a destructive replacement.

## 11. Tests

### Models

- payload encryption;
- account equality and uniqueness;
- personal consent rules;
- default access propagation;
- manifest serialization excludes disabled/foreign connections;
- Oura adoption leaves encrypted columns unchanged.

### Controllers

- account and personal scoping;
- durable concurrent OAuth attempts;
- callback state cannot change account/provider/owner;
- Dropbox profiles map to exact scopes;
- non-owner cannot broaden personal access;
- admin can reduce access;
- no secret appears in Inertia props.

### Runtime

- Docker args include tmpfs and staging bind;
- manifest file mode and location;
- persistent volumes never contain service credentials;
- recreation waits for active turns;
- successful reconciliation records revision;
- self-refresh does not require a Rails callback.

### Compatibility

- current Oura controller tests continue passing;
- current Oura sync/model tests continue passing;
- adoption and generic UI work with a connected legacy fixture;
- disconnecting only the account-scoped connection does not clear legacy tokens.

## 12. Rollout

1. Deploy additive migrations and dormant models.
2. Deploy services UI and Oura adoption with no automatic migration.
3. Configure Dropbox client id/secret and generic callback URL.
4. Run the disposable Dropbox proof with one resident.
5. Enable Oura adoption for existing users.
6. Observe reconciliation failures and provider refresh behavior.
7. Only then consider a separate plan to retire the legacy Oura model.

## 13. Rollback

- Disable the new routes/UI.
- Stop provisioning manifests and recreate affected resident containers.
- Leave all service rows for diagnosis.
- Existing Oura remains operational because its rows, controller, sync, and
  context path were never removed or rewritten.
