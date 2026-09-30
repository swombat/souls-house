# Audit Logging Implementation Plan (Final)

## Executive Summary

This plan implements a lean, semantic audit logging system for the Rails application following DHH's philosophy of simplicity and clarity. The system tracks user actions with meaningful names (e.g., `change_theme` instead of generic `update`) through a simple controller concern that creates audit log records with one line of code. This final revision removes i18n over-engineering and adds account tracking.

## Architecture Overview

The audit logging system consists of:
- One database table (`audit_logs`) with polymorphic associations
- One model (`AuditLog`) with minimal logic
- One controller concern (`Auditable`) providing a single helper method
- Uses existing authentication helpers (`current_user`, `current_account`) for context

## Implementation Steps

### Step 1: Create the Migration

- [ ] Generate migration: `rails generate migration CreateAuditLogs`
- [ ] Add the following table structure:

```ruby
class CreateAuditLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :audit_logs do |t|
      t.references :user, null: false, foreign_key: true
      t.references :account, foreign_key: true  # Track which account context
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
    add_index :audit_logs, [:account_id, :created_at]  # For account-scoped queries
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
  belongs_to :account, optional: true
  belongs_to :auditable, polymorphic: true, optional: true
  
  validates :action, presence: true
  
  scope :recent, -> { order(created_at: :desc) }
  scope :for_account, ->(account) { where(account: account) }
  
  # Simple humanization - no i18n needed
  def display_action
    action.to_s.humanize
  end
end
```

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
      account: current_account,  # May be nil for non-account-scoped actions
      action: action,
      auditable: auditable,
      changes: changes,
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
  end
end
```

**Design Notes:**
- No error rescue - if audit logging fails, we want to know about it
- Uses `current_user` and `current_account` helpers from existing concerns
- Account may be nil for actions like login/logout that happen outside account context

### Step 4: Add to ApplicationController

- [ ] Update `app/controllers/application_controller.rb`:

```ruby
class ApplicationController < ActionController::Base
  include Authentication
  include AccountScoping
  include Auditable  # Add this line
  
  # ... rest of the controller
end
```

### Step 5: Implement in Existing Controllers

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
      audit :login, user  # No account context yet
      redirect_to after_authentication_url
    else
      # Don't audit failed login attempts in the basic implementation
      redirect_to login_path, alert: "Try another email address or password."
    end
  end
  
  def destroy
    audit :logout, current_user  # Will include current_account if present
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
      # Direct creation since no current_user
      AuditLog.create!(
        user: user,
        account: nil,  # No account context
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
        account: nil,  # No account context
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

- [ ] For account-specific actions:

```ruby
class AccountsController < ApplicationController
  before_action :set_account, only: [:show, :edit, :update, :destroy]
  
  def create
    @account = current_user.accounts.build(account_params)
    @account.account_users.build(user: current_user, role: :owner)
    
    if @account.save
      audit :create_account, @account, { name: @account.name }
      redirect_to @account
    else
      render :new, status: :unprocessable_entity
    end
  end
  
  def update
    if @account.update(account_params)
      audit :update_account_settings, @account, account_params.to_h
      redirect_to @account
    else
      render :edit, status: :unprocessable_entity
    end
  end
  
  private
  
  def set_account
    @account = current_user.accounts.find(params[:id])
  end
  
  def account_params
    params.require(:account).permit(:name, :timezone, :billing_email)
  end
end

class AccountUsersController < ApplicationController
  before_action :set_account
  
  def create
    invited_user = User.find_or_invite(params[:email_address])
    account_user = @account.account_users.build(user: invited_user, role: params[:role])
    
    if account_user.save
      # This audit log will have both user and account context
      audit :invite_member, account_user, { 
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
    member_role = account_user.role
    
    account_user.destroy!
    
    audit :remove_member, @account, { 
      removed_email: member_email,
      removed_role: member_role
    }
    
    redirect_to account_members_path(@account)
  end
  
  def update_role
    account_user = @account.account_users.find(params[:id])
    old_role = account_user.role
    
    if account_user.update(role: params[:role])
      audit :change_member_role, account_user, {
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
    # When we set @account, it becomes the current account context for audit logs
  end
end
```

### Step 6: Update Routes for Semantic Actions

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

### Step 7: Write Tests

- [ ] Create test file: `test/models/audit_log_test.rb`

```ruby
require "test_helper"

class AuditLogTest < ActiveSupport::TestCase
  setup do
    @user = users(:john)
    @account = accounts(:acme)
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
  
  test "creates audit log with account context" do
    log = AuditLog.create!(
      user: @user,
      account: @account,
      action: :update_settings
    )
    
    assert log.persisted?
    assert_equal @account, log.account
  end
  
  test "allows nil account" do
    log = AuditLog.create!(
      user: @user,
      action: :login
    )
    
    assert log.persisted?
    assert_nil log.account
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
  
  test "display_action humanizes the action" do
    log = AuditLog.new(action: "change_theme")
    assert_equal "Change theme", log.display_action
    
    log = AuditLog.new(action: "update_account_settings")
    assert_equal "Update account settings", log.display_action
  end
  
  test "recent scope orders by created_at desc" do
    old_log = AuditLog.create!(user: @user, action: :old, created_at: 1.day.ago)
    new_log = AuditLog.create!(user: @user, action: :new, created_at: 1.hour.ago)
    
    assert_equal [new_log, old_log], AuditLog.recent.to_a
  end
  
  test "for_account scope filters by account" do
    acme_log = AuditLog.create!(user: @user, account: @account, action: :test)
    other_account = accounts(:widgets)
    other_log = AuditLog.create!(user: @user, account: other_account, action: :test)
    no_account_log = AuditLog.create!(user: @user, action: :login)
    
    assert_includes AuditLog.for_account(@account), acme_log
    assert_not_includes AuditLog.for_account(@account), other_log
    assert_not_includes AuditLog.for_account(@account), no_account_log
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
  
  test "successful login creates audit log without account" do
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
    assert_nil log.account  # No account context at login
  end
  
  test "logout creates audit log with account if present" do
    login_as(@user)
    # Assume user has a default account set
    
    assert_difference "AuditLog.count" do
      delete logout_url
    end
    
    log = AuditLog.last
    assert_equal @user, log.user
    assert_equal "logout", log.action
    assert_not_nil log.account if @user.default_account
  end
end
```

- [ ] Create account controller test: `test/controllers/account_users_controller_test.rb`

```ruby
require "test_helper"

class AccountUsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:john)
    @account = accounts(:acme)
    login_as(@user)
  end
  
  test "inviting member creates audit log with account context" do
    assert_difference "AuditLog.count" do
      post account_members_url(@account), params: {
        email_address: "new@example.com",
        role: "member"
      }
    end
    
    log = AuditLog.last
    assert_equal @user, log.user
    assert_equal @account, log.account
    assert_equal "invite_member", log.action
    assert_equal "new@example.com", log.changes["invited_email"]
  end
end
```

## Testing Strategy

1. **Model Tests**: Verify AuditLog creation, validations, scopes, and display_action
2. **Controller Tests**: Ensure audit logs are created with proper account context
3. **Integration Tests**: Test full flows including authentication and audit trail
4. **Manual Testing Checklist**:
   - [ ] Login creates audit log (no account context)
   - [ ] Logout creates audit log (with account if present)
   - [ ] User settings changes create audit logs with account
   - [ ] Account-specific actions include account in audit log
   - [ ] Actions outside account context have nil account
   - [ ] display_action properly humanizes action names
   - [ ] Audit failures cause visible errors (not silently swallowed)

## Key Design Decisions

1. **No i18n**: Simple humanization is sufficient - no need for translation complexity
2. **Account Tracking**: Audit logs track which account context the action occurred in
3. **No Error Rescue**: Let audit failures fail loudly
4. **Use Helper Methods**: Leverages existing `current_user` and `current_account`
5. **Semantic Routes**: Separate controller actions for different intents
6. **Direct Creation**: No unnecessary abstraction layers

## Edge Cases and Error Handling

1. **No Current User**: The helper checks for `current_user` and skips logging
2. **No Current Account**: Many actions (login, logout, password reset) have no account context
3. **Database Failures**: Let them fail - we want to know if audit logging is broken
4. **Unauthenticated Actions**: For password resets, directly create AuditLog
5. **Account Switching**: If users can switch accounts, current_account will reflect the active one

## Performance Considerations

1. **Synchronous Writing**: Audit logs are written in the same request
   - This is fine for most applications
   - Only optimize to background jobs if it becomes a measured problem
2. **Indexes**: Action, created_at, account_id, and polymorphic columns are indexed
3. **JSONB Storage**: Efficient for structured data storage and querying

## Security Considerations

1. **Immutable Records**: No update or destroy actions on audit logs
2. **User Association**: Always tied to the acting user when available
3. **Account Scoping**: Track which account context for multi-tenant security
4. **IP/User Agent Tracking**: Helps identify suspicious activity
5. **Sensitive Data Filtering**: Never log passwords, tokens, or secrets

## What We're NOT Building (YAGNI)

These features are intentionally excluded until actually needed:
- i18n translations for audit actions
- Background job processing
- Audit log retention/archiving
- Admin viewer UI
- Categorization or severity levels
- Webhook notifications
- Bulk operations support
- Failed attempt logging

## Rollback Plan

If issues arise:
1. Remove `include Auditable` from ApplicationController
2. Application continues normally without audit logging
3. Fix issues with audit logging
4. Re-enable the concern

## Success Criteria

- [ ] Audit logs are created for all significant user actions
- [ ] One-line implementation: `audit :action, object, data`
- [ ] Semantic action names that humanize nicely
- [ ] Account context tracked when available
- [ ] System fails visibly if audit logging breaks
- [ ] All tests pass
- [ ] No passwords or sensitive data in audit logs
- [ ] No performance degradation

## Example Queries

Once implemented, you'll be able to query audit logs:

```ruby
# All actions for a specific account
AuditLog.for_account(@account).recent

# All actions by a specific user
AuditLog.where(user: @user).recent

# All login events
AuditLog.where(action: :login).recent

# Actions in the last 24 hours for an account
AuditLog.for_account(@account).where(created_at: 24.hours.ago..).recent

# Find who invited a specific member
AuditLog.where(action: :invite_member, account: @account)
        .where("changes->>'invited_email' = ?", "john@example.com")
```

## Next Steps After Implementation

Once the Rails backend is complete and tested:
1. Consider adding an admin viewer (separate future task)
2. Monitor for performance issues (unlikely but possible)
3. Add more semantic actions as new features are built
4. Consider security monitoring dashboard if needed