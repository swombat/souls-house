# Security Remediation Plan

**Date**: 2026-03-21
**Status**: Ready for implementation
**Revision**: B
**Supersedes**: `docs/plans/260321-01-security-remediation.md`
**Incorporates feedback from**: `docs/plans/260321-01-security-remediation-dhh-feedback.md`

## Executive Summary

This revision keeps the scope the same but makes the implementation more explicit:

1. Use confirmed membership as the only account boundary.
2. Put account-manager and account-owner guards in the existing `AccountScoping` concern.
3. Make Telegram bot secrets write-only.
4. Harden `SyncChannel` entirely on the server side.
5. Use Rails token verification primitives that are already in the codebase.
6. Ship a concrete CSP in report-only mode before enforcing it.

No new auth framework. No Devise migration. No changes to `app/frontend/lib/use-sync.js`.

## Problems This Plan Fixes

### Critical

- Unconfirmed invitees can access account-scoped resources.
- Any account member can remove other members.
- `SyncChannel` performs reflective dispatch from user input.

### High

- Any account member can rename/convert accounts and manage shared agents/integrations.
- The agent edit page exposes the raw Telegram bot token.
- Confirmation and invitation links do not expire at redemption time.

### Medium

- Password reset and confirmation tokens are stored in usable plaintext.
- CSP is disabled in production.

## Security Principles

- Confirmed membership is the only valid account boundary.
- Shared account mutations require an explicit role check at the controller boundary.
- Secrets are write-only after storage.
- Signed or digested tokens are acceptable; raw bearer tokens stored in the database are not.
- Websocket subscription inputs must be allowlisted, never reflected.

## Architecture Decisions

### 1. Do not use `Current.user.accounts` as an authorization boundary

`User#accounts` goes through all memberships, including unconfirmed invites. That association can stay if it is useful elsewhere, but it must not be used for account authorization.

The auth boundary should instead be:

- `current_account` resolves through `memberships.confirmed`
- `default_account` returns only a confirmed account
- shared Inertia `accounts` data includes only confirmed accounts

The specific fallback that needs to die is:

```ruby
memberships.confirmed.first&.account || memberships.first&.account
```

If a user has no confirmed memberships, `default_account` should return `nil`.

### 2. Keep authorization guards in `AccountScoping`

Do not create a new concern for two guard methods. Put them next to the existing account-scoping logic:

```ruby
def require_account_manager!
  return if current_account&.manageable_by?(Current.user)
  redirect_back_or_to account_path(current_account), alert: "You don't have permission to manage this account"
end

def require_account_owner!
  return if current_account&.owned_by?(Current.user)
  redirect_back_or_to account_path(current_account), alert: "Only the account owner can perform this action"
end
```

For JSON requests, return `head :forbidden` instead of redirecting.

### 3. `SyncChannel` must be fixed without touching `use-sync.js`

The frontend helper is out of scope for this work. The server should be hardened while preserving the existing client contract.

The simplest path is:

- keep simple record subscriptions working
- delete `setup_collection_subscription`
- reject any subscription payload that tries to use the `id:collection` format

If the collection path must remain, it still needs a strict constant-based allowlist. But the bias should be deletion, not redesign.

### 4. Confirmation tokens already use Rails signing; redemption is the broken part

The app already uses:

```ruby
generates_token_for :email_confirmation, expires_in: 24.hours
```

The bug is that redemption ignores it and does:

```ruby
find_by!(confirmation_token: token)
```

The first fix is to use:

```ruby
find_by_token_for(:email_confirmation, token)
```

That closes the expiry/signature bug immediately. After that, stop depending on `confirmation_token` as a lookup key and phase out storing the raw signed token entirely.

### 5. Password reset should also use `generates_token_for`

Use the Rails primitive directly:

```ruby
generates_token_for :password_reset, expires_in: 2.hours do
  password_salt&.last(10)
end
```

Then replace raw lookup with:

```ruby
find_by_token_for(:password_reset, params[:token])
```

This makes the token expire automatically and invalidates it when the password changes.

### 6. Telegram bot tokens become write-only

The server should never serialize `telegram_bot_token` back to the browser. The edit page only needs:

- `telegram_configured?`
- `telegram_bot_username`
- webhook status
- subscriber count

Blank token submission means "leave unchanged." If token removal is needed, add an explicit reset action.

## Implementation Plan

### Step 1: Fix confirmed-membership account scoping

- [ ] Update `AccountScoping#current_account` to resolve via `Current.user.memberships.confirmed`, not `Current.user.accounts`.
- [ ] Update `User#default_account` to return only `memberships.confirmed.first&.account`.
- [ ] Update `ApplicationController#inertia_share` so `accounts:` is sourced from confirmed memberships only.
- [ ] Audit any direct `Current.user.accounts.find(...)` authorization usage and replace it where needed.

**Concrete target shape**

```ruby
def current_account
  @current_account ||= if params[:account_id]
    Current.user&.memberships&.confirmed&.find_by!(account_id: params[:account_id])&.account
  else
    Current.user&.default_account
  end
end

def default_account
  memberships.confirmed.first&.account
end
```

**Files likely touched**

- `app/controllers/concerns/account_scoping.rb`
- `app/models/user.rb`
- `app/controllers/application_controller.rb`

**Tests**

- Existing invited user cannot access `/accounts/:id`
- Existing invited user cannot access `/accounts/:id/chats/:id`
- Existing invited user does not receive the invited account in shared Inertia props
- Confirmed membership still works normally

### Step 2: Add manager/owner guards in `AccountScoping`

- [ ] Add `require_account_manager!` to `AccountScoping`.
- [ ] Add `require_account_owner!` to `AccountScoping`.
- [ ] Use `before_action` guards instead of inline conditionals where possible.

Apply `require_account_manager!` to:

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
- account rename in `AccountsController#update`

Apply `require_account_owner!` to:

- personal/team conversion in `AccountsController#update`

**Files likely touched**

- `app/controllers/concerns/account_scoping.rb`
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

### Step 3: Make Telegram token handling write-only

- [ ] Remove `telegram_bot_token` from the agent edit payload.
- [ ] Treat blank token submission as "unchanged."
- [ ] Add an explicit token reset action only if the product needs one.
- [ ] Keep Telegram webhook registration and test-send endpoints behind `require_account_manager!`.

**Files likely touched**

- `app/controllers/agents_controller.rb`
- `app/models/concerns/telegram_notifiable.rb`
- `app/frontend/pages/agents/edit.svelte`
- related tests

**Tests**

- Agent edit response does not include the raw Telegram token
- Updating an agent without a token does not erase an existing token
- Token reset path, if added, behaves explicitly

### Step 4: Harden `SyncChannel` on the server only

- [ ] Add a frozen `ALLOWED_MODELS` constant in `SyncChannel`.
- [ ] Reject any model name not in the constant.
- [ ] Delete `setup_collection_subscription`.
- [ ] Reject `params[:id]` values that try to use `id:collection` format.

**Concrete target shape**

```ruby
class SyncChannel < ApplicationCable::Channel
  ALLOWED_MODELS = %w[Account Agent AgentMemory AuditLog Chat Message Setting Whiteboard].freeze

  def subscribed
    return reject unless params[:model].in?(ALLOWED_MODELS)
    return reject if params[:id].to_s.include?(":")

    model_class = params[:model].constantize
    @model = model_class.find_by_obfuscated_id(params[:id])
    return reject unless @model&.accessible_by?(current_user)

    stream_from "#{params[:model]}:#{params[:id]}"
  end
end
```

If a real, shipping feature depends on collection subscriptions, revisit this after the critical fix. Do not change `app/frontend/lib/use-sync.js` as part of this work.

**Files likely touched**

- `app/channels/sync_channel.rb`
- `test/channels/sync_channel_test.rb`

**Tests**

- Unknown model is rejected
- `id:destroy` style payload is rejected
- Unauthorized record is rejected
- Legitimate subscriptions still connect

### Step 5: Fix confirmation and invitation redemption with Rails token verification

- [ ] Change `Membership.confirm_by_token!` to use `find_by_token_for(:email_confirmation, token)`.
- [ ] Stop treating `confirmation_token` as a DB lookup key.
- [ ] Keep `confirmation_sent_at` for resend tracking.
- [ ] In a follow-up cleanup, stop storing the raw signed token in `confirmation_token` at all.

**Immediate target shape**

```ruby
def self.confirm_by_token!(token)
  raise ActiveSupport::MessageVerifier::InvalidSignature if token.blank?

  membership = find_by_token_for(:email_confirmation, token)
  raise ActiveSupport::MessageVerifier::InvalidSignature unless membership

  membership.confirm!
  membership
end
```

**Cleanup follow-up**

- mailers generate the signed token on demand
- `confirmation_token` column becomes obsolete and can be removed later

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

### Step 6: Replace password reset flow with `generates_token_for`

- [ ] Replace `has_secure_token :password_reset_token` with `generates_token_for :password_reset, expires_in: 2.hours`.
- [ ] Include password salt in the token block so password changes invalidate the token.
- [ ] Replace raw lookup in `PasswordsController` with `find_by_token_for(:password_reset, params[:token])`.
- [ ] Remove `password_reset_expired?` and other raw-token plumbing once the signed flow is live.
- [ ] Remove the `password_reset_token` column in a follow-up migration.

**Concrete target shape**

```ruby
generates_token_for :password_reset, expires_in: 2.hours do
  password_salt&.last(10)
end
```

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
- Token is invalid after password change
- Tampered reset link fails

### Step 7: Add a concrete CSP and minor hygiene fixes

- [ ] Enable `content_security_policy` in `config/initializers/content_security_policy.rb`.
- [ ] Start in `report_only`.
- [ ] Keep the policy narrow and explicit.
- [ ] Change the `FaviconController` `system` call to argv form.

**Starting CSP**

```ruby
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data, :https
    policy.img_src     :self, :data, :https
    policy.object_src  :none
    policy.script_src  :self
    policy.style_src   :self, :unsafe_inline
    policy.connect_src :self, :https, :wss

    if Rails.env.development?
      policy.script_src *policy.script_src, :unsafe_eval, "http://#{ViteRuby.config.host_with_port}"
      policy.connect_src *policy.connect_src, "ws://#{ViteRuby.config.host_with_port}"
    end
  end

  config.content_security_policy_report_only = true
end
```

**Favicon fix**

```ruby
system("rsvg-convert", "-w", "32", "-h", "32", "-f", "png", "-o", temp_file.path, svg_path.to_s)
```

**Files likely touched**

- `config/initializers/content_security_policy.rb`
- `app/controllers/favicon_controller.rb`

## Rollout Order

Ship this in four PRs:

1. Confirmed-membership scoping + `AccountScoping` guards
2. Telegram secret handling + shared integration protection
3. `SyncChannel` hardening
4. Confirmation/reset token cleanup + CSP/hygiene follow-up

This keeps the privilege-escalation fixes first and isolates the most user-visible token-flow changes.

## Deployment Notes

### Confirmation links

When redemption switches to verified tokens, already-sent links may need to be treated as expired. That is acceptable if:

- resend works
- the failure message clearly tells the user to request a new link

### Password reset links

Existing reset links should be treated as expired when the new token format ships. Safer to invalidate than to support dual formats indefinitely.

### Telegram credentials

If non-admin users could already see or control bot credentials, rotate those tokens operationally after the fix ships.

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
- Any changes to `app/frontend/lib/use-sync.js`
