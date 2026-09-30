# Audit Logging Implementation Plan

## Executive Summary

This plan implements a lean, semantic audit logging system for the Rails application following DHH's philosophy of simplicity and clarity. The system tracks user actions with meaningful names (e.g., `change_theme` instead of generic `update`) through a simple controller concern that creates audit log records with one line of code.

## Architecture Overview

The audit logging system consists of:
- One database table (`audit_logs`) with polymorphic associations
- One model (`AuditLog`) with minimal logic
- One controller concern (`Auditable`) providing a single helper method
- Integration with existing `Current` attributes for user tracking

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
  
  # Dead simple creation - no magic, no DSL, just data
  def self.record(user:, action:, auditable: nil, changes: {}, request: nil)
    create!(
      user: user,
      action: action,
      auditable: auditable,
      changes: changes,
      ip_address: request&.remote_ip,
      user_agent: request&.user_agent
    )
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
    return unless Current.user # Skip if no user context (e.g., system operations)
    
    AuditLog.record(
      user: Current.user,
      action: action,
      auditable: auditable,
      changes: changes,
      request: request
    )
  rescue => e
    # Log the error but don't break the request
    Rails.logger.error "Audit logging failed: #{e.message}"
    # Optionally notify error tracking service
  end
end
```

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

### Step 5: Add Semantic Action Translations (Optional)

- [ ] Update `config/locales/en.yml`:

```yaml
en:
  audit:
    actions:
      # User actions
      change_theme: "Changed theme"
      change_password: "Changed password"
      update_profile: "Updated profile"
      enable_two_factor: "Enabled two-factor authentication"
      disable_two_factor: "Disabled two-factor authentication"
      
      # Session actions
      login: "Logged in"
      logout: "Logged out"
      
      # Account actions
      create_account: "Created account"
      update_account: "Updated account settings"
      invite_member: "Invited team member"
      remove_member: "Removed team member"
      change_member_role: "Changed member role"
```

### Step 6: Implement in Existing Controllers

#### Example: Sessions Controller

- [ ] Update `app/controllers/sessions_controller.rb`:

```ruby
class SessionsController < ApplicationController
  allow_unauthenticated_access
  
  def create
    user = User.find_by(email_address: params[:email_address])
    
    if user && user.authenticate(params[:password])
      start_new_session_for(user)
      audit :login, user  # Add this line
      redirect_to after_authentication_url
    else
      redirect_to login_path, alert: "Try another email address or password."
    end
  end
  
  def destroy
    audit :logout, Current.user  # Add this line
    terminate_session
    redirect_to root_path
  end
end
```

#### Example: Users Controller (for profile updates)

- [ ] Update user-related controllers:

```ruby
def update
  @user = Current.user
  
  if @user.update(user_params)
    # Semantic logging based on what was actually changed
    if user_params.key?(:theme)
      audit :change_theme, @user, { from: @user.theme_was, to: @user.theme }
    elsif user_params.key?(:password)
      audit :change_password, @user
    else
      audit :update_profile, @user, user_params.slice(:first_name, :last_name, :email_address)
    end
    
    redirect_to profile_path, notice: "Profile updated successfully"
  else
    render :edit, status: :unprocessable_entity
  end
end
```

#### Example: Account Management

- [ ] For account-related actions:

```ruby
class AccountUsersController < ApplicationController
  def create
    @account = Current.user.accounts.find(params[:account_id])
    @invited_user = User.find_or_invite(params[:email_address])
    @account_user = @account.account_users.build(user: @invited_user, role: params[:role])
    
    if @account_user.save
      audit :invite_member, @account_user, { 
        account: @account.name, 
        invited_email: @invited_user.email_address,
        role: params[:role]
      }
      AccountUserMailer.invitation(@account_user).deliver_later
      redirect_to account_members_path(@account)
    else
      render :new, status: :unprocessable_entity
    end
  end
  
  def destroy
    @account = Current.user.accounts.find(params[:account_id])
    @account_user = @account.account_users.find(params[:id])
    member_email = @account_user.user.email_address
    
    @account_user.destroy
    audit :remove_member, nil, { 
      account: @account.name, 
      removed_email: member_email 
    }
    
    redirect_to account_members_path(@account)
  end
end
```

### Step 7: Write Tests

- [ ] Create test file: `test/models/audit_log_test.rb`

```ruby
require "test_helper"

class AuditLogTest < ActiveSupport::TestCase
  setup do
    @user = users(:john)
    @request = OpenStruct.new(remote_ip: "127.0.0.1", user_agent: "Test Browser")
  end
  
  test "records audit log with all attributes" do
    log = AuditLog.record(
      user: @user,
      action: :test_action,
      auditable: @user,
      changes: { test: "data" },
      request: @request
    )
    
    assert log.persisted?
    assert_equal @user, log.user
    assert_equal "test_action", log.action
    assert_equal @user, log.auditable
    assert_equal({ "test" => "data" }, log.changes)
    assert_equal "127.0.0.1", log.ip_address
    assert_equal "Test Browser", log.user_agent
  end
  
  test "allows nil auditable" do
    log = AuditLog.record(
      user: @user,
      action: :logout,
      request: @request
    )
    
    assert log.persisted?
    assert_nil log.auditable
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
end
```

- [ ] Create controller test: `test/controllers/concerns/auditable_test.rb`

```ruby
require "test_helper"

class AuditableTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:john)
    login_as(@user)
  end
  
  test "audit helper creates audit log" do
    assert_difference "AuditLog.count" do
      patch user_url(@user), params: { user: { theme: "dark" } }
    end
    
    log = AuditLog.last
    assert_equal @user, log.user
    assert_equal "change_theme", log.action
  end
  
  test "audit helper handles errors gracefully" do
    # Simulate database error
    AuditLog.stub :record, ->(*) { raise ActiveRecord::RecordInvalid.new(AuditLog.new) } do
      assert_nothing_raised do
        patch user_url(@user), params: { user: { theme: "dark" } }
      end
    end
  end
  
  test "audit skips when no user present" do
    logout
    
    assert_no_difference "AuditLog.count" do
      post login_url, params: { email_address: "wrong@example.com", password: "wrong" }
    end
  end
end
```

## Testing Strategy

1. **Model Tests**: Verify AuditLog creation, validations, and scopes
2. **Controller Tests**: Ensure audit logs are created for key actions
3. **Integration Tests**: Test full flows including authentication and audit trail
4. **Manual Testing Checklist**:
   - [ ] Login creates audit log
   - [ ] Logout creates audit log
   - [ ] Profile updates create semantic audit logs
   - [ ] Failed actions don't create audit logs
   - [ ] System can continue if audit logging fails

## Edge Cases and Error Handling

1. **No Current User**: The helper checks for `Current.user` and skips logging if absent
2. **Database Failures**: Audit failures are logged but don't break the request
3. **Large Change Sets**: JSONB can handle large data, but consider limiting what's logged
4. **Concurrent Requests**: Each request creates its own audit log (no race conditions)
5. **Missing Translations**: Falls back to humanized action name

## Performance Considerations

1. **Synchronous Writing**: Audit logs are written in the same request
   - For high-traffic actions, consider moving to background jobs later (YAGNI for now)
2. **Indexes**: Action, created_at, and polymorphic columns are indexed for fast queries
3. **JSONB Storage**: Efficient for querying and storing structured data

## Security Considerations

1. **Immutable Records**: No update or destroy actions on audit logs
2. **User Association**: Always tied to the acting user
3. **IP Tracking**: Helps identify suspicious activity
4. **Sensitive Data**: Controllers should filter what goes into `changes` hash

## Future Enhancements (When Needed)

These are NOT part of the initial implementation (YAGNI):
- Background job processing for high-volume actions
- Audit log retention policies and archiving
- Advanced filtering and search UI
- Categorization and severity levels
- Webhook notifications for critical actions
- Bulk operations support

## Rollback Plan

If issues arise:
1. Remove `include Auditable` from ApplicationController
2. Audit logging stops but application continues normally
3. Existing audit logs remain for investigation
4. Can be re-enabled after fixes

## Success Criteria

- [ ] Audit logs are created for all significant user actions
- [ ] One-line implementation in controllers
- [ ] Semantic action names provide clear audit trail
- [ ] System continues operating if audit logging fails
- [ ] All tests pass
- [ ] No performance degradation in normal operations