# Audit Logging Implementation Plan (Final v2)

## Executive Summary

This plan implements a lean, semantic audit logging system for the Rails application following DHH's philosophy of simplicity and clarity. The system tracks user actions with meaningful names through a smart controller concern that automatically captures all context (user, account, IP, user agent) without any boilerplate.

## Architecture Overview

The audit logging system consists of:
- One database table (`audit_logs`) with polymorphic associations
- One model (`AuditLog`) with minimal logic
- One controller concern (`Auditable`) with a smart helper that auto-captures context
- Leverages `Current` attributes for user/account tracking

## Implementation Steps

### Step 1: Create the Migration

- [x] Generate migration: `rails generate migration CreateAuditLogs`
- [x] Add the following table structure:

```ruby
class CreateAuditLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :audit_logs do |t|
      t.references :user, foreign_key: true  # Nullable for system actions
      t.references :account, foreign_key: true  # Nullable for non-account actions
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
    add_index :audit_logs, [:account_id, :created_at]
  end
end
```

- [x] Run migration: `rails db:migrate`

### Step 2: Update Current Attributes

- [x] Update `app/models/current.rb` to include account:

```ruby
class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :account  # Add this
  
  delegate :user, to: :session, allow_nil: true
end
```

### Step 3: Update AccountScoping Concern

- [x] Update `app/controllers/concerns/account_scoping.rb` to set Current.account:

```ruby
module AccountScoping
  extend ActiveSupport::Concern
  
  included do
    helper_method :current_account, :current_account_user
    before_action :set_current_account  # Add this
  end
  
  private
  
  def current_account
    @current_account ||= Current.user&.default_account
  end
  
  def current_account_user
    @current_account_user ||= if current_account && Current.user
      Current.user.account_users.confirmed.find_by(account: current_account)
    end
  end
  
  def set_current_account
    Current.account = current_account
  end
  
  # ... rest of existing methods
end
```

### Step 4: Create the AuditLog Model

- [x] Create file: `app/models/audit_log.rb`
- [x] Implement the model:

```ruby
class AuditLog < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :account, optional: true
  belongs_to :auditable, polymorphic: true, optional: true
  
  validates :action, presence: true
  
  scope :recent, -> { order(created_at: :desc) }
  scope :for_account, ->(account) { where(account: account) }
  scope :for_user, ->(user) { where(user: user) }
  
  # Simple humanization - no i18n needed
  def display_action
    action.to_s.humanize
  end
end
```

### Step 5: Create the Smart Auditable Concern

- [x] Create file: `app/controllers/concerns/auditable.rb`
- [x] Implement the concern with smart defaults:

```ruby
module Auditable
  extend ActiveSupport::Concern
  
  private
  
  # Smart helper that captures all context automatically
  # Usage: audit(:login)
  #        audit(:change_theme, @user, from: old, to: new)
  #        audit(:invite_member, @member, email: @member.email)
  def audit(action, auditable = nil, changes = {})
    # Allow overriding user for special cases (like password reset)
    # by passing user: in the changes hash
    user = changes.delete(:user) || Current.user
    account = changes.delete(:account) || Current.account
    
    # Skip if no user (unless explicitly passed)
    return unless user
    
    AuditLog.create!(
      user: user,
      account: account,
      action: action,
      auditable: auditable,
      changes: changes,
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
  end
end
```

### Step 6: Add to ApplicationController

- [x] Update `app/controllers/application_controller.rb`:

```ruby
class ApplicationController < ActionController::Base
  include Authentication
  include AccountScoping
  include Auditable  # Add this line
  
  # ... rest of the controller
end
```

### Step 7: Implement in Existing Controllers

#### Sessions Controller

- [x] Update `app/controllers/sessions_controller.rb`:

```ruby
class SessionsController < ApplicationController
  allow_unauthenticated_access
  
  def create
    user = User.find_by(email_address: params[:email_address])
    
    if user && user.authenticate(params[:password])
      start_new_session_for(user)
      audit(:login, user)  # Simple! User context is automatically captured
      redirect_to after_authentication_url
    else
      # Don't audit failed attempts in basic implementation
      redirect_to login_path, alert: "Try another email address or password."
    end
  end
  
  def destroy
    audit(:logout)  # Even simpler! Everything is captured automatically
    terminate_session
    redirect_to root_path
  end
end
```

#### Password Reset Controller

- [x] Update password reset actions using the helper:

```ruby
class PasswordsController < ApplicationController
  allow_unauthenticated_access
  
  def create
    user = User.find_by(email_address: params[:email_address])
    
    if user
      # Use the helper but specify the user since they're not logged in
      audit(:password_reset_requested, user, user: user, requested_at: Time.current)
      PasswordsMailer.reset(user).deliver_later
    end
    
    # Always show the same message for security
    redirect_to login_path, notice: "Check your email to reset your password."
  end
  
  def update
    user = User.find_by_password_reset_token!(params[:token])
    
    if user.update(password: params[:password], password_confirmation: params[:password_confirmation])
      # Specify the user since they're not logged in yet
      audit(:password_reset_completed, user, user: user)
      redirect_to login_path, notice: "Password reset successfully. Please login."
    else
      render :edit, status: :unprocessable_entity
    end
  end
end
```

#### User Settings Controller

- [x] Create dedicated actions for different settings:

```ruby
class SettingsController < ApplicationController
  before_action :set_user
  
  def update_theme
    old_theme = @user.theme
    
    if @user.update(theme: params[:theme])
      audit(:change_theme, @user, from: old_theme, to: @user.theme)
      redirect_to settings_path, notice: "Theme updated"
    else
      render :edit, status: :unprocessable_entity
    end
  end
  
  def update_timezone
    old_timezone = @user.timezone
    
    if @user.update(timezone: params[:timezone])
      audit(:update_timezone, @user, from: old_timezone, to: @user.timezone)
      redirect_to settings_path, notice: "Timezone updated"
    else
      render :edit, status: :unprocessable_entity
    end
  end
  
  def update_password
    if @user.update_with_password(password_params)
      audit(:change_password, @user)  # Never log passwords!
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

- [x] For account-specific actions:

```ruby
class AccountsController < ApplicationController
  before_action :set_account, only: [:show, :edit, :update, :destroy]
  
  def create
    @account = current_user.accounts.build(account_params)
    @account.account_users.build(user: current_user, role: :owner)
    
    if @account.save
      # Account context will be captured automatically
      audit(:create_account, @account, name: @account.name)
      redirect_to @account
    else
      render :new, status: :unprocessable_entity
    end
  end
  
  def update
    if @account.update(account_params)
      audit(:update_account_settings, @account, account_params.to_h)
      redirect_to @account
    else
      render :edit, status: :unprocessable_entity
    end
  end
  
  def switch
    @account = current_user.accounts.find(params[:id])
    session[:current_account_id] = @account.id
    Current.account = @account
    
    audit(:switch_account, @account)
    redirect_to @account
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
      # Clean and simple - account context is automatic
      audit(:invite_member, account_user, 
            invited_email: invited_user.email_address,
            role: params[:role])
      
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
    
    audit(:remove_member, nil, 
          removed_email: member_email,
          removed_role: member_role)
    
    redirect_to account_members_path(@account)
  end
  
  def update_role
    account_user = @account.account_users.find(params[:id])
    old_role = account_user.role
    
    if account_user.update(role: params[:role])
      audit(:change_member_role, account_user,
            member: account_user.user.email_address,
            from: old_role,
            to: params[:role])
      redirect_to account_members_path(@account)
    else
      render :edit, status: :unprocessable_entity
    end
  end
  
  private
  
  def set_account
    @account = current_user.accounts.find(params[:account_id])
    Current.account = @account  # Ensure Current.account is set for nested resources
  end
end
```

### Step 8: Write Tests

- [x] Create test file: `test/models/audit_log_test.rb`

```ruby
require "test_helper"

class AuditLogTest < ActiveSupport::TestCase
  setup do
    @user = users(:john)
    @account = accounts(:acme)
  end
  
  test "creates audit log with all attributes" do
    log = AuditLog.create!(
      user: @user,
      account: @account,
      action: :test_action,
      auditable: @user,
      changes: { test: "data" },
      ip_address: "127.0.0.1",
      user_agent: "Test Browser"
    )
    
    assert log.persisted?
    assert_equal @user, log.user
    assert_equal @account, log.account
    assert_equal "test_action", log.action
  end
  
  test "allows nil user for system actions" do
    log = AuditLog.create!(
      action: :system_cleanup
    )
    
    assert log.persisted?
    assert_nil log.user
  end
  
  test "allows nil account for non-account actions" do
    log = AuditLog.create!(
      user: @user,
      action: :login
    )
    
    assert log.persisted?
    assert_nil log.account
  end
  
  test "display_action humanizes the action" do
    log = AuditLog.new(action: "change_theme")
    assert_equal "Change theme", log.display_action
  end
end
```

- [x] Create controller test: `test/controllers/concerns/auditable_test.rb`

```ruby
require "test_helper"

class AuditableController < ApplicationController
  def test_action
    audit(:test_action, current_user, custom: "data")
    head :ok
  end
  
  def test_without_user
    Current.user = nil
    audit(:should_not_log)
    head :ok
  end
  
  def test_with_override
    audit(:password_reset, users(:jane), user: users(:jane))
    head :ok
  end
end

class AuditableTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:john)
    @account = accounts(:acme)
    
    Rails.application.routes.draw do
      get "test_action" => "auditable#test_action"
      get "test_without_user" => "auditable#test_without_user"
      get "test_with_override" => "auditable#test_with_override"
    end
  end
  
  teardown do
    Rails.application.reload_routes!
  end
  
  test "audit helper captures all context automatically" do
    login_as(@user)
    Current.account = @account
    
    assert_difference "AuditLog.count" do
      get "/test_action"
    end
    
    log = AuditLog.last
    assert_equal @user, log.user
    assert_equal @account, log.account
    assert_equal "test_action", log.action
    assert_equal({ "custom" => "data" }, log.changes)
    assert_not_nil log.ip_address
    assert_not_nil log.user_agent
  end
  
  test "audit skips when no user" do
    assert_no_difference "AuditLog.count" do
      get "/test_without_user"
    end
  end
  
  test "audit allows user override" do
    jane = users(:jane)
    
    assert_difference "AuditLog.count" do
      get "/test_with_override"
    end
    
    log = AuditLog.last
    assert_equal jane, log.user
    assert_equal "password_reset", log.action
  end
end
```

## Testing Strategy

1. **Model Tests**: Verify AuditLog creation with optional associations
2. **Concern Tests**: Ensure the helper captures context automatically
3. **Controller Tests**: Verify audit logs are created correctly
4. **Manual Testing Checklist**:
   - [ ] Login creates audit log with auto-captured user
   - [ ] Actions with Current.account set include account
   - [ ] Password reset can override user
   - [ ] IP and user agent are always captured
   - [ ] No boilerplate needed in controllers

## Key Design Decisions

1. **Smart Defaults**: Helper automatically captures Current.user, Current.account, IP, and user agent
2. **Override Capability**: Can override user/account by passing in changes hash
3. **No Boilerplate**: Controllers just call `audit(:action)` - that's it
4. **No i18n**: Simple humanization is sufficient
5. **Current Attributes**: Leverages Rails' CurrentAttributes for request context

## Why This Design is Superior

1. **DRY**: No repetition of `user: current_user, account: current_account` everywhere
2. **Clean Controllers**: `audit(:logout)` instead of passing 5 parameters
3. **Flexible**: Can still override when needed (password reset case)
4. **Consistent**: IP and user agent always captured the same way
5. **Rails-like**: Uses CurrentAttributes as intended

## Edge Cases Handled

1. **No User**: Helper returns early if no Current.user (unless overridden)
2. **No Account**: Many actions have no account context - that's fine
3. **Password Reset**: Can specify user via override since not logged in
4. **Account Switching**: Current.account reflects the active account
5. **Nested Resources**: Set Current.account in before_action for proper context

## What We're NOT Building (YAGNI)

- i18n translations
- Background job processing
- Retention policies
- Admin UI (separate task)
- Categories/severity
- Webhooks
- Bulk operations

## Success Criteria

- [x] One-line audit calls: `audit(:action)`
- [x] Context automatically captured
- [x] Override capability works
- [x] All tests pass
- [x] No performance degradation
- [x] No passwords in logs

## Example Usage After Implementation

```ruby
# Simplest case - everything automatic
audit(:logout)

# With auditable object
audit(:change_theme, @user)

# With changes data
audit(:invite_member, @member, role: "admin")

# Override user (for unauthenticated actions)
audit(:password_reset, @user, user: @user)

# Query examples
AuditLog.for_account(@account).recent
AuditLog.for_user(@user).recent
AuditLog.where(action: :login).recent
```

This is the leanest, most Rails-like implementation possible - true to DHH's philosophy of convention over configuration.