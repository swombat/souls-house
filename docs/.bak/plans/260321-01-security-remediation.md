# Security Remediation Plan

**Date**: 2026-03-21
**Status**: Ready for implementation
**Priority**: Critical
**Revision**: A

## Executive Summary

This plan remediates the major security issues identified in the March 21 audit without changing the product shape or adding new dependencies. The focus is straightforward Rails hardening:

1. Require confirmed membership before any account-scoped access.
2. Enforce explicit account-role checks for shared administration actions.
3. Remove Telegram credential disclosure from the agent UI.
4. Eliminate reflective dispatch from `SyncChannel`.
5. Replace raw confirmation/reset bearer tokens with verified expiring tokens.
6. Add a minimal browser-security baseline in production.

The implementation should use Rails primitives already in the app. No Pundit, no Devise migration, no new policy framework.

## Findings Addressed

### Critical

- Unconfirmed invitees can access account-scoped resources before accepting the invite.
- Any account member can remove other members.
- `SyncChannel` accepts user-controlled class and method dispatch.

### High

- Any account member can rename/convert accounts and manage shared agents/integrations.
- The agent edit page exposes the raw Telegram bot token.
- Confirmation and invitation links do not actually expire when redeemed.

### Medium

- Password reset and confirmation tokens are stored in usable plaintext.
- CSP is disabled in production.

## Security Principles

- Account access requires a confirmed membership, not just a related row in `memberships`.
- Shared account mutations require an explicit role check in the controller layer.
- Secrets are write-only after save unless there is a strong product reason to reveal them.
- Tokenized flows must rely on signed or digested tokens, not raw bearer values stored in the database.
- Websocket subscriptions must be allowlisted, not reflective.

## Architecture Decisions

### 1. Confirmed membership is the only valid account boundary

The app currently has two conflicting rules:

- `Account#accessible_by?` uses confirmed memberships.
- `AccountScoping#current_account` resolves through `Current.user.accounts`, which includes unconfirmed invites.

The confirmed-membership rule should win everywhere. There should be one clear access boundary and every account-scoped controller should inherit it.

### 2. Shared administration needs two levels

Use the model methods that already exist:

- `manageable_by?` for normal account administration.
- `owned_by?` for ownership-shaping operations.

Proposed rule:

- `manageable_by?`: invite/remove members, create/edit/delete agents, manage shared integrations, trigger shared agent jobs, register Telegram webhooks, run Telegram test sends.
- `owned_by?`: convert personal/team account type.

Renaming the account can remain manager-level.

### 3. Telegram bot secrets become write-only

The UI should never receive `telegram_bot_token` after it has been stored. The edit page only needs:

- whether Telegram is configured
- username
- webhook state
- subscriber count

If the user submits an empty token field, the server should interpret that as "leave unchanged," not "clear the token." If token removal is needed, add a dedicated disconnect/reset action.

### 4. Reflective channel behavior should be deleted unless proven necessary

The simplest safe fix for `SyncChannel` is to remove the dynamic collection branch entirely if nothing in the real frontend depends on it. The current frontend code appears to subscribe to simple model/id pairs, not arbitrary method calls on records.

If collection subscriptions are genuinely needed, they must be implemented through an explicit allowlist:

- allowed model names
- allowed collection names per model
- authorization checks on every streamed record

No `safe_constantize` from params. No `send` from params.

### 5. Token flows should use Rails verification, not raw lookup

The confirmation and password-reset flows should move to Rails-signed or digested tokens. The current pattern stores a usable bearer token in the database and then looks it up directly. That needs to end.

For confirmation/invitation links:

- generate an expiring signed token
- redeem it through Rails token verification
- stop trusting `confirmation_token` as a DB lookup key

For password resets:

- use Rails signed reset tokens or a stored digest
- do not store a raw reusable token

## Implementation Plan

### Step 1: Fix account scoping to require confirmed membership

- [ ] Add a confirmed-membership-backed path for account resolution.
- [ ] Update `AccountScoping#current_account` to resolve only through confirmed membership.
- [ ] Update `User#default_account` so pending invites do not become an access path.
- [ ] Audit account-scoped controllers to ensure they rely on the shared scoping rule instead of ad hoc account lookup.

**Files likely touched**

- `app/controllers/concerns/account_scoping.rb`
- `app/models/user.rb`
- potentially `app/models/account.rb`

**Tests**

- Existing invited user cannot access `/accounts/:id`
- Existing invited user cannot access `/accounts/:id/chats/:id`
- Existing invited user cannot access `/accounts/:id/agents`
- Confirmed membership still works normally

### Step 2: Add explicit authorization guards for shared administration

- [ ] Add controller helpers such as `require_account_manager!` and `require_account_owner!`.
- [ ] Apply manager-level protection to:
  - `AccountMembersController#destroy`
  - `AgentsController#create/edit/update/destroy`
  - `Agents::RefinementsController#create`
  - `Agents::MemoriesController#create`
  - `Agents::Memories::ProtectionsController`
  - `Agents::Memories::DiscardsController`
  - `Agents::TelegramWebhooksController#create`
  - `Agents::TelegramTestsController#create`
  - `GithubIntegrationController`
  - `XIntegrationController`
  - `Accounts::AgentInitiationsController#create`
- [ ] Split `AccountsController#update` so:
  - rename is manager-only
  - account-type conversion is owner-only

**Files likely touched**

- `app/controllers/application_controller.rb` or a new controller concern
- `app/controllers/accounts_controller.rb`
- `app/controllers/account_members_controller.rb`
- `app/controllers/agents_controller.rb`
- `app/controllers/agents/*.rb`
- `app/controllers/github_integration_controller.rb`
- `app/controllers/x_integration_controller.rb`
- `app/controllers/accounts/agent_initiations_controller.rb`

**Tests**

- Regular member cannot remove another member
- Regular member cannot rename account
- Regular member cannot convert account type
- Regular member cannot edit/delete agents
- Regular member cannot connect/disconnect GitHub/X integrations
- Owner/admin behavior still passes

### Step 3: Remove Telegram credential disclosure and make secret handling write-only

- [ ] Stop serializing `telegram_bot_token` into Inertia props.
- [ ] Keep update semantics write-only: blank token means unchanged.
- [ ] Add a dedicated reset/disconnect action if the product needs token removal.
- [ ] Ensure Telegram webhook registration and test-send endpoints stay manager-only.

**Files likely touched**

- `app/controllers/agents_controller.rb`
- `app/models/concerns/telegram_notifiable.rb`
- `app/frontend/pages/agents/edit.svelte`
- related tests

**Tests**

- Agent edit response does not include the raw Telegram token
- Updating an agent without a token does not erase an existing token
- Token reset path, if added, behaves explicitly

### Step 4: Harden `SyncChannel`

- [ ] Replace dynamic class resolution with an explicit model allowlist.
- [ ] Remove `setup_collection_subscription` entirely if nothing real depends on it.
- [ ] If collection subscriptions remain, replace `send` with a strict allowlist.
- [ ] Ensure a malformed or malicious subscription cannot invoke side effects before rejection.

**Files likely touched**

- `app/channels/sync_channel.rb`
- `app/frontend/lib/use-sync.js` only if the channel contract changes
- `test/channels/sync_channel_test.rb`

**Tests**

- Unknown model is rejected
- Unauthorized record is rejected
- Arbitrary method names are rejected
- Legitimate subscriptions still connect

### Step 5: Replace confirmation and invitation token redemption with verified expiring tokens

- [ ] Stop redeeming confirmations with `find_by!(confirmation_token: token)`.
- [ ] Use Rails token verification for confirmation/invitation acceptance.
- [ ] Stop depending on `confirmation_token` as a persisted bearer secret.
- [ ] Decide rollout behavior for already-sent links:
  - simplest: invalidate them and require resend
  - alternative: short transition window with dual validation, then cleanup

The simpler, safer approach is to invalidate old links and rely on resend.

**Files likely touched**

- `app/models/concerns/confirmable.rb`
- `app/models/membership.rb`
- `app/controllers/registrations_controller.rb`
- `app/mailers/account_mailer.rb`
- confirmation-related tests

**Tests**

- Fresh confirmation link works
- Expired confirmation link fails
- Tampered confirmation link fails
- Resend issues a new working link

### Step 6: Replace password reset tokens with signed or digested tokens

- [ ] Remove raw lookup by `password_reset_token`.
- [ ] Use a signed reset token or stored digest instead.
- [ ] Ensure reset tokens expire and become invalid after successful password change.
- [ ] Add a follow-up cleanup migration to remove the raw token column once the new flow is live.

**Files likely touched**

- `app/models/concerns/authenticatable.rb`
- `app/controllers/passwords_controller.rb`
- `app/mailers/passwords_mailer.rb`
- `db/migrate/*` for cleanup
- password reset tests

**Tests**

- Fresh reset link works
- Expired reset link fails
- Used reset link cannot be reused
- Tampered reset link fails

### Step 7: Add production browser and hygiene hardening

- [ ] Enable a real CSP in `config/initializers/content_security_policy.rb`.
- [ ] Start with a policy narrow enough for the current app rather than a giant permissive allowlist.
- [ ] If rollout risk is high, ship `report_only` first, then enforce.
- [ ] Change the `FaviconController` shell invocation to argv form or a non-shell path.
- [ ] Re-run Brakeman after each phase.

**Files likely touched**

- `config/initializers/content_security_policy.rb`
- `app/controllers/favicon_controller.rb`

## Rollout Order

Ship this in four small PRs rather than one giant security branch:

1. Confirmed-membership scoping + controller authorization guards
2. Telegram secret handling + shared integration protection
3. `SyncChannel` hardening
4. Token flow replacement + CSP/hygiene follow-up

This keeps the highest-risk privilege-escalation fixes first and isolates the token-flow rollout, which has the highest chance of affecting legitimate users.

## Deployment Notes

### Confirmation / invitation links

Changing the confirmation flow will likely invalidate already-sent links. That is acceptable if:

- the resend path is working
- the error message clearly instructs the user to request a new link

### Password reset links

If the reset flow changes token format, existing reset links should be treated as expired. This is safer than supporting both indefinitely.

### Shared account operations

After the authorization fix lands, some users who could previously manage agents/integrations will lose that ability. That is a bug fix, not a regression, but it should be called out in the release notes.

## Verification Checklist

- [ ] Minitest coverage added for every privilege boundary touched
- [ ] Channel tests cover malformed subscription payloads
- [ ] Manual smoke test: owner/admin can still manage account, agents, and integrations
- [ ] Manual smoke test: invited-but-unconfirmed user cannot access account resources
- [ ] Manual smoke test: confirmation resend and password reset still work end-to-end
- [ ] `bundle exec brakeman --no-exit-on-warn`

## Out of Scope

- Full authorization framework adoption
- Reworking sessions or replacing custom authentication
- Broad frontend redesign
- Secret rotation for already-exposed third-party credentials outside the app

Credential rotation may still be required operationally for any Telegram bot token that was exposed to unauthorized users before this fix ships.
