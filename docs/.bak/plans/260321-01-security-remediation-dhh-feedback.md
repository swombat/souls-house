# Security Remediation Plan -- DHH-Style Review

**Reviewer**: Claude (channeling DHH)
**Date**: 2026-03-21
**Document reviewed**: `docs/plans/260321-01-security-remediation.md`

---

## Overall Assessment

This is a well-written security plan that respects the Rails Way. It does not reach for Pundit. It does not invent a policy framework. It does not propose a migration to Devise. It correctly identifies that the app already has the right primitives -- `manageable_by?`, `owned_by?`, `accessible_by?`, confirmed membership scopes -- and that the real problem is these primitives are not applied consistently at the boundaries where they matter. That is the right diagnosis and the right instinct.

The plan is direct, the rollout is sensible, and the scope is appropriately limited. There are a few places where it is either too vague or slightly misreads the existing code, and one place where it overlooks that Rails already solved the problem it is describing. Let me go through each.

---

## What Works Well

**The philosophy is dead right.** "No Pundit, no Devise migration, no new policy framework." This is exactly how you harden a Rails app. You do not bolt on an authorization gem to fix three controller actions. You add `before_action` guards and move on with your life.

**The confirmed-membership-as-boundary principle is clean.** One rule, applied everywhere. The plan correctly identifies the split brain between `Account#accessible_by?` (which checks confirmed memberships) and `AccountScoping#current_account` (which resolves through `Current.user.accounts`, which includes unconfirmed ones). That is a real bug and the fix is straightforward.

**The rollout order is correct.** Privilege escalation first, credential disclosure second, channel hardening third, token flow changes last. This minimizes user-facing breakage while shipping the most dangerous fixes first.

**Write-only secrets is the right pattern.** Once a Telegram bot token is stored, the UI should never see it again. The plan gets this right and even handles the "blank means unchanged" semantics correctly.

**SyncChannel analysis is accurate and the recommendation is sharp.** `send(params[:id].split(":")[1])` on line 32 of `sync_channel.rb` is genuinely dangerous. The plan correctly identifies that the frontend does not appear to use collection subscriptions at all -- the `use-sync.js` code parses collection suffixes but never actually passes them to the channel subscription. The recommendation to delete `setup_collection_subscription` entirely is the right call.

---

## Issues and Recommendations

### 1. The confirmation token problem is already half-solved -- the plan does not notice

The `Confirmable` concern already uses `generates_token_for :email_confirmation, expires_in: 24.hours`. This is Rails 7.1's built-in signed, expiring token generation. The token is generated correctly in `generate_confirmation_token` via `generate_token_for(:email_confirmation)`.

The real issue is narrower than the plan describes. The problem is not "the app stores raw bearer tokens and looks them up directly." The problem is that `Membership.confirm_by_token!` does exactly that:

```ruby
def self.confirm_by_token!(token)
  membership = find_by!(confirmation_token: token)
  membership.confirm!
  membership
end
```

It stores the signed token in `confirmation_token` and then finds by it as if it were a simple lookup key. This means:

1. The token is stored in plaintext in the database (the signed token itself).
2. Redemption does not verify the signature or check expiry -- it just does `find_by!`.
3. The token is never invalidated by the expiry mechanism built into `generates_token_for`.

The fix is to use `find_by_token_for(:email_confirmation, token)` instead of `find_by!(confirmation_token: token)`. That is one line. The `confirmation_token` column can then become a simple marker for "has a pending confirmation" rather than a lookup key. The plan should say this explicitly rather than gesturing at "use Rails token verification." The mechanism is already in the codebase -- it is just not being used at the redemption step.

**Recommendation**: Step 5 should be rewritten to say: "Replace `find_by!(confirmation_token: token)` with `find_by_token_for(:email_confirmation, token)` in `Membership.confirm_by_token!`. This uses the signed token verification that `generates_token_for` already provides. Then stop storing the raw signed token in `confirmation_token` -- store a digest or a boolean flag instead."

### 2. The password reset fix should also use `generates_token_for`

The `Authenticatable` concern uses `has_secure_token :password_reset_token`, which generates a random token and stores it in plaintext. The plan says to "use Rails signed reset tokens or a stored digest" but does not name the specific mechanism.

Rails 7.1 gives you `generates_token_for :password_reset, expires_in: 2.hours` with automatic invalidation when the password changes (by including the password salt in the token generation block). The earlier architecture plans for this project actually specified this exact pattern -- it appears to have been lost somewhere along the way.

**Recommendation**: Step 6 should specify: "Replace `has_secure_token :password_reset_token` with `generates_token_for :password_reset, expires_in: 2.hours do; password_salt&.last(10); end`. Replace `find_by(password_reset_token: params[:token])` with `find_by_token_for(:password_reset, params[:token])`. Remove `password_reset_token` column in a follow-up migration." This is not a novel design decision -- it is using the Rails primitive that was designed for exactly this purpose.

### 3. Step 2 proposes helpers but does not show the pattern

The plan says "Add controller helpers such as `require_account_manager!` and `require_account_owner!`" but does not specify where they live or what they look like. For a security fix, the implementation pattern matters. Here is what I would expect:

```ruby
# In AccountScoping concern (not a new concern -- this belongs with the other account-scoped logic)
def require_account_manager!
  unless current_account&.manageable_by?(Current.user)
    redirect_to unauthorized_path, alert: "You don't have permission to manage this account"
  end
end

def require_account_owner!
  unless current_account&.owned_by?(Current.user)
    redirect_to unauthorized_path, alert: "Only the account owner can perform this action"
  end
end
```

Then controllers use them as `before_action`:

```ruby
class AccountMembersController < ApplicationController
  before_action :require_account_manager!, only: [:destroy]
  # ...
end
```

This is two methods, six lines of code, in an existing concern. The plan should say this explicitly. "A new controller concern" is unnecessary indirection for two methods.

**Recommendation**: Specify that `require_account_manager!` and `require_account_owner!` live in `AccountScoping` as `before_action`-compatible guards. No new files.

### 4. The `current_account` fix needs more precision

The plan says to "Update `AccountScoping#current_account` to resolve only through confirmed membership." The current code is:

```ruby
def current_account
  @current_account ||= if params[:account_id]
    Current.user&.accounts&.find(params[:account_id])
  else
    Current.user&.default_account
  end
end
```

The problem is `Current.user.accounts` goes through `has_many :accounts, through: :memberships`, which includes unconfirmed memberships. The fix is to scope through confirmed memberships:

```ruby
def current_account
  @current_account ||= if params[:account_id]
    Current.user&.memberships&.confirmed&.find_by!(account_id: params[:account_id])&.account
  else
    Current.user&.default_account
  end
end
```

And `User#default_account` needs the same treatment. Currently:

```ruby
def default_account
  memberships.confirmed.first&.account || memberships.first&.account
end
```

That fallback to `memberships.first&.account` is the bug. It should be:

```ruby
def default_account
  memberships.confirmed.first&.account
end
```

If there are no confirmed memberships, `default_account` should return `nil`. The plan identifies both of these but should be more explicit about the fallback being the actual vulnerability.

**Recommendation**: Call out the `|| memberships.first&.account` fallback in `default_account` as the primary exploit path. It is the single line that lets unconfirmed invitees access account resources.

### 5. The `inertia_share` in `ApplicationController` also leaks unconfirmed accounts

The plan does not mention this, but `ApplicationController#inertia_share` sends:

```ruby
accounts: Current.user.accounts.map(&:as_json)
```

This sends all accounts -- including those with unconfirmed memberships -- to the frontend on every authenticated request. This is both a data leak and a UX problem (the user sees accounts they cannot actually access). This should be scoped to confirmed memberships as well.

**Recommendation**: Add to Step 1: "Update `inertia_share` in `ApplicationController` to scope `accounts` through confirmed memberships only."

### 6. The FaviconController shell injection concern is real but the fix is trivial

The plan mentions this in passing under Step 7. The issue is on line 21 of `favicon_controller.rb`:

```ruby
system("rsvg-convert -w 32 -h 32 -f png -o #{temp_file.path} #{svg_path}")
```

Both `temp_file.path` and `svg_path` are server-controlled (not user input), so the actual risk is low. But the idiom is still wrong. Use the array form:

```ruby
system("rsvg-convert", "-w", "32", "-h", "32", "-f", "png", "-o", temp_file.path, svg_path.to_s)
```

Honestly, this entire controller should be replaced with a pre-generated PNG served as a static asset. Converting SVG to PNG on every favicon request is absurd, even with caching. But that is a performance concern, not a security one, and it is correctly out of scope.

**Recommendation**: The plan has this right. Just fix the system call to argv form and move on.

### 7. The CSP section is too vague

"Start with a policy narrow enough for the current app" does not tell the implementer anything. The app uses Vite, ActionCable (WebSocket), and likely loads fonts and images from known origins. A useful starting point would be:

```ruby
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    policy.img_src     :self, :data, :https
    policy.object_src  :none
    policy.script_src  :self
    policy.style_src   :self, :unsafe_inline  # Tailwind/DaisyUI needs this
    policy.connect_src :self, "wss://#{Rails.application.config.action_cable.url || 'localhost'}"

    if Rails.env.development?
      policy.script_src *policy.script_src, :unsafe_eval, "http://#{ViteRuby.config.host_with_port}"
      policy.connect_src *policy.connect_src, "ws://#{ViteRuby.config.host_with_port}"
    end
  end

  config.content_security_policy_report_only = true  # Start in report-only
end
```

Ship `report_only` first, watch for violations, then enforce. The plan says this but does not provide the starting policy.

**Recommendation**: Include a concrete starting CSP in the plan. Report-only first is the right call.

### 8. Step 4's SyncChannel allowlist should be a simple constant

The plan says "explicit model allowlist" but does not show what that looks like. It should be dead simple:

```ruby
class SyncChannel < ApplicationCable::Channel
  ALLOWED_MODELS = %w[Account Agent Chat Message Whiteboard AgentMemory].freeze

  def subscribed
    return reject unless params[:model].in?(ALLOWED_MODELS)

    model_class = params[:model].constantize
    # ... rest of subscription logic
  end
end
```

A frozen array constant. Not a configuration file. Not a registry. Not a class method that subclasses can override. A constant.

**Recommendation**: Show the allowlist pattern in the plan. Make clear it is a constant, not a configuration mechanism.

---

## Minor Observations

**The "four small PRs" recommendation is good** but PR 1 is doing two things: confirmed-membership scoping AND controller authorization guards. These could be separate, but combining them is defensible since neither is useful without the other. Keep it as-is.

**The test lists are solid.** Every step has concrete test scenarios. The "regular member cannot X" tests in Step 2 are exactly right -- test the negative cases, not just the happy path.

**The "out of scope" section is appropriately restrained.** Resisting the urge to rework sessions or adopt a full authorization framework shows good judgment. Fix what is broken, ship it, move on.

---

## Summary of Recommended Changes to the Plan

1. **Step 5**: Be specific -- replace `find_by!(confirmation_token: token)` with `find_by_token_for(:email_confirmation, token)`. The mechanism already exists in the codebase.

2. **Step 6**: Be specific -- use `generates_token_for :password_reset, expires_in: 2.hours` with password salt. Replace raw token lookup with `find_by_token_for`. This was the original design intent that got lost.

3. **Step 2**: Put `require_account_manager!` and `require_account_owner!` in the existing `AccountScoping` concern. No new files.

4. **Step 1**: Call out the `|| memberships.first&.account` fallback in `User#default_account` as the primary exploit path. Add `inertia_share` account scoping to this step.

5. **Step 4**: Show the `ALLOWED_MODELS` constant pattern for `SyncChannel`.

6. **Step 7**: Provide a concrete starting CSP policy.

The plan is fundamentally sound. These are refinements to make it implementable without further design decisions. A good plan tells the implementer exactly what to type. This one is 80% there -- the remaining 20% is naming the specific Rails primitives that already exist for each problem.
