# Audit Logging Implementation Plan (Revised)

## Executive Summary

This plan implements a lean, semantic audit logging system for the Rails application following DHH's philosophy of simplicity and clarity. The system tracks user actions with meaningful names (e.g., `change_theme` instead of generic `update`) through a simple controller concern that creates audit log records with one line of code. This revision incorporates feedback to make the implementation even more Rails-idiomatic.

## Architecture Overview

The audit logging system consists of:
- One database table (`audit_logs`) with polymorphic associations
- One model (`AuditLog`) with minimal logic
- One controller concern (`Auditable`) providing a single helper method
- Uses existing authentication helpers (`current_user`) for user tracking

## Implementation Steps

### Step 1: Create the Migration

- [ ] Generate migration: `rails generate migration CreateAuditLogs`
- [ ] Add the following table structure:

```ruby
class CreateAuditLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :audit_logs do |t|
      t.references :user, null: false, foreign_key: true
      t.references :auditable, polymorphic: true
      t.string :action, null: false
      t.jsonb :changes, default: {}
      t.string :ip_address
      t.string :user_agent
      
      t.datetime :created_at, null: false
    end
    
    add_index :audit_logs, :action
    add_index :audit_logs, :created_at
    add_index :audit_logs, [:auditable_type, :auditable_id]
  end
end
```

- [ ] Run migration: `rails db:migrate`

### Step 2: Create the AuditLog Model

- [ ] Create file: `app/models/audit_log.rb`
- [ ] Implement the model:

```ruby
class AuditLog < ApplicationRecord
  belongs_to :user
  belongs_to :auditable, polymorphic: true, optional: true
  
  validates :action, presence: true
  
  scope :recent, -> { order(created_at: :desc) }
  
  # Simple semantic helper - returns human-readable action if defined, otherwise the raw action
  def display_action
    I18n.t("audit.actions.#{action}", default: action.humanize)
  end
end
```

Note: The model is intentionally simple. It doesn't need a `record` class method - we'll just use `create!` directly.

### Step 3: Create the Auditable Concern

- [ ] Create file: `app/controllers/concerns/auditable.rb`
- [ ] Implement the concern:

```ruby
module Auditable
  extend ActiveSupport::Concern
  
  private
  
  # One line, one purpose - record what happened
  def audit(action, auditable = nil, changes = {})
    # Use the conventional current_user helper from Authentication concern
    return unless current_user
    
    AuditLog.create!(
      user: current_user,
      action: action,
      auditable: auditable,
      changes: changes,
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
  end
end
```

**Important Design Decisions:**
- No error rescue - if audit logging fails, we want to know about it
- Uses `current_user` helper method (defined via `Current.user` in Authentication concern)
- Directly creates the audit log without unnecessary abstraction

### Step 4: Update Authentication Concern

- [ ] Verify that `app/controllers/concerns/authentication.rb` includes the helper:

```ruby
module Authentication
  extend ActiveSupport::Concern
  
  included do
    before_action :require_authentication
    helper_method :authenticated?, :current_user  # Add current_user if not present
  end
  
  # ... existing code ...
  
  private
  
  def current_user
    Current.user
  end
end
```

### Step 5: Add to ApplicationController

- [ ] Update `app/controllers/application_controller.rb`:

```ruby
class ApplicationController < ActionController::Base
  include Authentication
  include AccountScoping
  include Auditable  # Add this line
  
  # ... rest of the controller
end
```

### Step 6: Add Semantic Action Translations (Optional)

- [ ] Update `config/locales/en.yml`:

```yaml
en:
  audit:
    actions:
      # Authentication actions
      login: "Logged in"
      logout: "Logged out"
      password_reset_requested: "Requested password reset"
      password_reset_completed: "Reset password"
      
      # User actions
      change_theme: "Changed theme"
      change_password: "Changed password"
      update_profile: "Updated profile"
      update_timezone: "Changed timezone"
      
      # Account actions
      create_account: "Created account"
      update_account_settings: "Updated account settings"
      
      # Account member actions
      invite_member: "Invited team member"
      remove_member: "Removed team member"
      change_member_role: "Changed member role"
      accept_invitation: "Accepted invitation"
```

### Step 7: Implement in Existing Controllers

#### Sessions Controller

- [ ] Update `app/controllers/sessions_controller.rb`:

```ruby
class SessionsController < ApplicationController
  allow_unauthenticated_access
  
  def new
    # No audit needed for viewing login page
  end
  
  def create
    user = User.find_by(email_address: params[:email_address])
    
    if user && user.authenticate(params[:password])
      start_new_session_for(user)
      audit :login, user
      redirect_to after_authentication_url
    else
      # Don't audit failed login attempts in the basic implementation
      # Add this later if security monitoring is needed
      redirect_to login_path, alert: "Try another email address or password."
    end
  end
  
  def destroy
    audit :logout, current_user
    terminate_session
    redirect_to root_path
  end
end
```

#### Password Reset Controller

- [ ] Update password reset actions:

```ruby
class PasswordsController < ApplicationController
  allow_unauthenticated_access
  
  def create
    user = User.find_by(email_address: params[:email_address])
    
    if user
      # Use a simple audit without current_user since they're not logged in
      # We'll need to handle this case specially
      AuditLog.create!(
        user: user,
        action: :password_reset_requested,
        auditable: user,
        changes: { requested_at: Time.current },
        ip_address: request.remote_ip,
        user_agent: request.user_agent
      )
      
      PasswordsMailer.reset(user).deliver_later
    end
    
    # Always show the same message for security
    redirect_to login_path, notice: "Check your email to reset your password."
  end
  
  def update
    user = User.find_by_password_reset_token!(params[:token])
    
    if user.update(password: params[:password], password_confirmation: params[:password_confirmation])
      # Log this important security event
      AuditLog.create!(
        user: user,
        action: :password_reset_completed,
        auditable: user,
        ip_address: request.remote_ip,
        user_agent: request.user_agent
      )
      
      redirect_to login_path, notice: "Password reset successfully. Please login."
    else
      render :edit, status: :unprocessable_entity
    end
  end
end
```

#### User Settings Controller

- [ ] Create dedicated actions for different settings:

```ruby
class SettingsController < ApplicationController
  before_action :set_user
  
  def edit
    # Show settings form
  end
  
  def update_theme
    old_theme = @user.theme
    
    if @user.update(theme: params[:theme])
      audit :change_theme, @user, { from: old_theme, to: @user.theme }
      redirect_to settings_path, notice: "Theme updated"
    else
      render :edit, status: :unprocessable_entity
    end
  end
  
  def update_timezone
    old_timezone = @user.timezone
    
    if @user.update(timezone: params[:timezone])
      audit :update_timezone, @user, { from: old_timezone, to: @user.timezone }
      redirect_to settings_path, notice: "Timezone updated"
    else
      render :edit, status: :unprocessable_entity
    end
  end
  
  def update_password
    if @user.update_with_password(password_params)
      audit :change_password, @user
      redirect_to settings_path, notice: "Password changed"
    else
      render :edit, status: :unprocessable_entity
    end
  end
  
  private
  
  def set_user
    @user = current_user
  end
  
  def password_params
    params.require(:user).permit(:current_password, :password, :password_confirmation)
  end
end
```

#### Account Management

- [ ] For account-related actions:

```ruby
class AccountUsersController < ApplicationController
  before_action :set_account
  
  def create
    invited_user = User.find_or_invite(params[:email_address])
    account_user = @account.account_users.build(user: invited_user, role: params[:role])
    
    if account_user.save
      audit :invite_member, account_user, { 
        account: @account.name, 
        invited_email: invited_user.email_address,
        role: params[:role]
      }
      AccountUserMailer.invitation(account_user).deliver_later
      redirect_to account_members_path(@account)
    else
      render :new, status: :unprocessable_entity
    end
  end
  
  def destroy
    account_user = @account.account_users.find(params[:id])
    member_email = account_user.user.email_address
    
    account_user.destroy!
    
    audit :remove_member, @account, { 
      removed_email: member_email,
      removed_role: account_user.role
    }
    
    redirect_to account_members_path(@account)
  end
  
  def update_role
    account_user = @account.account_users.find(params[:id])
    old_role = account_user.role
    
    if account_user.update(role: params[:role])
      audit :change_member_role, account_user, {
        account: @account.name,
        member: account_user.user.email_address,
        from: old_role,
        to: params[:role]
      }
      redirect_to account_members_path(@account)
    else
      render :edit, status: :unprocessable_entity
    end
  end
  
  private
  
  def set_account
    @account = current_user.accounts.find(params[:account_id])
  end
end
```

### Step 8: Update Routes for Semantic Actions

- [ ] Update `config/routes.rb` to support semantic actions:

```ruby
Rails.application.routes.draw do
  # ... existing routes ...
  
  resource :settings, only: [:edit] do
    patch :theme, action: :update_theme
    patch :timezone, action: :update_timezone
    patch :password, action: :update_password
  end
  
  resources :accounts do
    resources :members, controller: :account_users do
      member do
        patch :role, action: :update_role
      end
    end
  end
  
  # ... rest of routes ...
end
```

### Step 9: Write Tests

- [ ] Create test file: `test/models/audit_log_test.rb`

```ruby
require "test_helper"

class AuditLogTest < ActiveSupport::TestCase
  setup do
    @user = users(:john)
  end
  
  test "creates audit log with required attributes" do
    log = AuditLog.create!(
      user: @user,
      action: :test_action,
      auditable: @user,
      changes: { test: "data" },
      ip_address: "127.0.0.1",
      user_agent: "Test Browser"
    )
    
    assert log.persisted?
    assert_equal @user, log.user
    assert_equal "test_action", log.action
    assert_equal @user, log.auditable
    assert_equal({ "test" => "data" }, log.changes)
  end
  
  test "allows nil auditable" do
    log = AuditLog.create!(
      user: @user,
      action: :logout
    )
    
    assert log.persisted?
    assert_nil log.auditable
  end
  
  test "requires action" do
    log = AuditLog.new(user: @user)
    assert_not log.valid?
    assert_includes log.errors[:action], "can't be blank"
  end
  
  test "display_action uses i18n when available" do
    log = AuditLog.new(action: "change_theme")
    I18n.backend.store_translations(:en, audit: { actions: { change_theme: "Theme Changed" } })
    
    assert_equal "Theme Changed", log.display_action
  end
  
  test "display_action falls back to humanize" do
    log = AuditLog.new(action: "custom_action")
    assert_equal "Custom action", log.display_action
  end
  
  test "recent scope orders by created_at desc" do
    old_log = AuditLog.create!(user: @user, action: :old, created_at: 1.day.ago)
    new_log = AuditLog.create!(user: @user, action: :new, created_at: 1.hour.ago)
    
    assert_equal [new_log, old_log], AuditLog.recent.to_a
  end
end
```

- [ ] Create controller test: `test/controllers/sessions_controller_test.rb`

```ruby
require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:john)
  end
  
  test "successful login creates audit log" do
    assert_difference "AuditLog.count" do
      post login_url, params: { 
        email_address: @user.email_address, 
        password: "secret" 
      }
    end
    
    log = AuditLog.last
    assert_equal @user, log.user
    assert_equal "login", log.action
    assert_equal @user, log.auditable
  end
  
  test "failed login does not create audit log" do
    assert_no_difference "AuditLog.count" do
      post login_url, params: { 
        email_address: @user.email_address, 
        password: "wrong" 
      }
    end
  end
  
  test "logout creates audit log" do
    login_as(@user)
    
    assert_difference "AuditLog.count" do
      delete logout_url
    end
    
    log = AuditLog.last
    assert_equal @user, log.user
    assert_equal "logout", log.action
  end
end
```

## Testing Strategy

1. **Model Tests**: Verify AuditLog creation, validations, and scopes
2. **Controller Tests**: Ensure audit logs are created for key actions
3. **Integration Tests**: Test full flows including authentication and audit trail
4. **Manual Testing Checklist**:
   - [ ] Login creates audit log with IP and user agent
   - [ ] Logout creates audit log
   - [ ] Theme changes create semantic audit logs with old/new values
   - [ ] Password changes create audit logs (without recording passwords!)
   - [ ] Failed actions don't create audit logs
   - [ ] Audit failures cause visible errors (not silently swallowed)

## Key Design Decisions

1. **No Error Rescue**: Let audit failures fail loudly - if it's important enough to log, it's important enough to know when it breaks
2. **Use current_user Helper**: Leverages existing authentication pattern instead of directly accessing Current.user
3. **Semantic Routes**: Separate controller actions for different user intents (update_theme vs update_password)
4. **Direct Creation**: No unnecessary `record` class method - just use `create!` directly
5. **Symbols for Actions**: Consistently use symbols for action names as they're more idiomatic

## Edge Cases and Error Handling

1. **No Current User**: The helper checks for `current_user` and skips logging if absent
2. **Database Failures**: Let them fail - we want to know if audit logging is broken
3. **Unauthenticated Actions**: For password resets, directly create AuditLog without the helper
4. **Large Change Sets**: Be selective about what goes into the `changes` hash
5. **Sensitive Data**: Never log passwords, tokens, or other sensitive information

## Performance Considerations

1. **Synchronous Writing**: Audit logs are written in the same request
   - This is fine for most applications
   - Only optimize to background jobs if it becomes a measured problem
2. **Indexes**: Action, created_at, and polymorphic columns are indexed
3. **JSONB Storage**: Efficient for structured data storage and querying

## Security Considerations

1. **Immutable Records**: No update or destroy actions on audit logs
2. **User Association**: Always tied to the acting user when available
3. **IP/User Agent Tracking**: Helps identify suspicious activity
4. **Sensitive Data Filtering**: Controllers must filter what goes into `changes`
5. **No Password Logging**: Never include passwords or tokens in audit data

## What We're NOT Building (YAGNI)

These features are intentionally excluded until actually needed:
- Background job processing
- Audit log retention/archiving
- Admin viewer UI
- Categorization or severity levels
- Webhook notifications
- Bulk operations support
- Failed attempt logging (could add later for security)

## Rollback Plan

If issues arise:
1. Remove `include Auditable` from ApplicationController
2. Application continues normally without audit logging
3. Fix issues with audit logging
4. Re-enable the concern

## Success Criteria

- [ ] Audit logs are created for all significant user actions
- [ ] One-line implementation in controllers: `audit :action, object, data`
- [ ] Semantic action names provide clear audit trail
- [ ] System fails visibly if audit logging breaks (no silent failures)
- [ ] All tests pass
- [ ] No passwords or sensitive data in audit logs
- [ ] No performance degradation in normal operations

## Next Steps After Implementation

Once the Rails backend is complete and tested:
1. Consider adding an admin viewer (separate future task)
2. Monitor for performance issues (unlikely but possible)
3. Add more semantic actions as new features are built
4. Consider failed attempt logging if security monitoring needed