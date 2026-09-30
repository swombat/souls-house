# Account Management Implementation Plan

## Executive Summary

This plan outlines the implementation of a comprehensive account management system for HelixKit, introducing multi-tenancy support through Account and AccountUser models. The design maintains backward compatibility with the existing authentication system while laying the foundation for team accounts and advanced permission systems.

## Architecture Overview

### Core Design Principles
- **Row-based multi-tenancy**: Using account_id to scope data within shared tables
- **Flexible account types**: Support for both personal and team accounts
- **Join model pattern**: AccountUser serves as the relationship between Users and Accounts
- **Progressive enhancement**: Minimal changes to existing authentication flow
- **Security first**: Confirmation tokens scoped to account relationships

### Data Flow
```
User Registration → Create User → Create Account → Create AccountUser (with token) → Send Confirmation
Email Confirmation → Find AccountUser by token → Confirm relationship → Set password → Login
```

## Database Schema Design

### 1. Accounts Table
```ruby
create_table :accounts do |t|
  t.string :name, null: false
  t.integer :account_type, null: false, default: 0  # enum: personal/team
  t.string :slug                                     # for future URL-friendly identifiers
  t.jsonb :settings, default: {}                    # flexible settings storage
  t.timestamps
  
  # Indexes
  t.index :slug, unique: true
  t.index :account_type
  t.index :created_at
end
```

### 2. Account Users Table (Join Model)
```ruby
create_table :account_users do |t|
  t.references :account, null: false, foreign_key: true
  t.references :user, null: false, foreign_key: true
  t.string :role, null: false, default: 'owner'     # owner/admin/member
  t.string :confirmation_token                       # moved from users table
  t.datetime :confirmation_sent_at
  t.datetime :confirmed_at
  t.datetime :invited_at                            # for team invitations
  t.string :invited_by_id                           # user who sent invite
  t.timestamps
  
  # Indexes
  t.index [:account_id, :user_id], unique: true
  t.index :confirmation_token, unique: true
  t.index :user_id
  t.index [:account_id, :role]
  t.index :confirmed_at
end
```

### 3. Modified Users Table
```ruby
# Migration to update users table
class UpdateUsersForAccounts < ActiveRecord::Migration[8.0]
  def change
    # Keep confirmation fields temporarily for migration
    # Will be removed in a follow-up migration after data migration
    add_column :users, :migrated_to_account_users, :boolean, default: false
    
    # Add default account reference for quick access
    add_reference :users, :default_account, foreign_key: { to_table: :accounts }
  end
end
```

### 4. Database Constraints
```sql
-- Ensure personal accounts have only one user
CREATE OR REPLACE FUNCTION check_personal_account_single_user()
RETURNS TRIGGER AS $$
BEGIN
  IF (SELECT account_type FROM accounts WHERE id = NEW.account_id) = 0 THEN
    IF (SELECT COUNT(*) FROM account_users WHERE account_id = NEW.account_id) > 0 THEN
      RAISE EXCEPTION 'Personal accounts can only have one user';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER enforce_personal_account_single_user
BEFORE INSERT ON account_users
FOR EACH ROW EXECUTE FUNCTION check_personal_account_single_user();
```

## Model Implementation

### 1. Account Model
```ruby
# app/models/account.rb
class Account < ApplicationRecord
  # Enums
  enum :account_type, { personal: 0, team: 1 }
  
  # Associations
  has_many :account_users, dependent: :destroy
  has_many :users, through: :account_users
  has_one :owner_membership, -> { where(role: 'owner') }, 
          class_name: 'AccountUser'
  has_one :owner, through: :owner_membership, source: :user
  
  # Validations
  validates :name, presence: true
  validates :account_type, presence: true
  validate :personal_account_single_user, if: :personal?
  
  # Callbacks
  before_validation :generate_slug, on: :create
  
  # Scopes
  scope :personal, -> { where(account_type: :personal) }
  scope :team, -> { where(account_type: :team) }
  
  private
  
  def personal_account_single_user
    if personal? && users.count > 1
      errors.add(:base, "Personal accounts can only have one user")
    end
  end
  
  def generate_slug
    self.slug ||= name.parameterize if name.present?
  end
end
```

### 2. AccountUser Model
```ruby
# app/models/account_user.rb
class AccountUser < ApplicationRecord
  # Constants
  ROLES = %w[owner admin member].freeze
  
  # Associations
  belongs_to :account
  belongs_to :user
  belongs_to :invited_by, class_name: 'User', optional: true
  
  # Validations
  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :account_id }
  validate :personal_account_owner_role
  
  # Callbacks
  before_create :generate_confirmation_token, if: :needs_confirmation?
  
  # Scopes
  scope :confirmed, -> { where.not(confirmed_at: nil) }
  scope :unconfirmed, -> { where(confirmed_at: nil) }
  scope :owners, -> { where(role: 'owner') }
  scope :admins, -> { where(role: ['owner', 'admin']) }
  
  # Token generation (similar to User model pattern)
  generates_token_for :email_confirmation, expires_in: 24.hours do
    [account_id, user_id, user.email_address].join('-')
  end
  
  def confirmed?
    confirmed_at.present?
  end
  
  def confirm!
    touch(:confirmed_at)
    update_column(:confirmation_token, nil)
  end
  
  def owner?
    role == 'owner'
  end
  
  def admin?
    role.in?(['owner', 'admin'])
  end
  
  def send_confirmation_email
    AccountMailer.confirmation(self).deliver_later
  end
  
  private
  
  def personal_account_owner_role
    if account&.personal? && role != 'owner'
      errors.add(:role, "must be owner for personal accounts")
    end
  end
  
  def generate_confirmation_token
    self.confirmation_token = generate_token_for(:email_confirmation)
    self.confirmation_sent_at = Time.current
  end
  
  def needs_confirmation?
    confirmation_token.blank? && confirmed_at.blank?
  end
end
```

### 3. Updated User Model
```ruby
# app/models/user.rb - additions/changes
class User < ApplicationRecord
  # Existing code...
  
  # New associations
  has_many :account_users, dependent: :destroy
  has_many :accounts, through: :account_users
  belongs_to :default_account, class_name: 'Account', optional: true
  
  # Remove confirmation-related callbacks and methods
  # These move to AccountUser
  
  def personal_account
    accounts.personal.first
  end
  
  def confirmed_accounts
    account_users.confirmed.includes(:account).map(&:account)
  end
  
  # Keep this for backward compatibility during migration
  def confirmed?
    account_users.confirmed.any?
  end
  
  # Override to check account confirmation
  def can_login?
    confirmed? && password_digest?
  end
end
```

## Service Objects

### 1. Registration Service
```ruby
# app/services/registration_service.rb
class RegistrationService
  attr_reader :email, :user, :account, :account_user
  
  def initialize(email)
    @email = email.strip.downcase
  end
  
  def execute
    ActiveRecord::Base.transaction do
      find_or_create_user
      handle_registration
    end
    
    send_confirmation_email unless @account_user.confirmed?
    self
  rescue ActiveRecord::RecordInvalid => e
    @errors = e.record.errors
    self
  end
  
  def success?
    @errors.nil?
  end
  
  def errors
    @errors || {}
  end
  
  def confirmation_resent?
    @confirmation_resent
  end
  
  private
  
  def find_or_create_user
    @user = User.find_or_initialize_by(email_address: @email)
  end
  
  def handle_registration
    if @user.persisted?
      handle_existing_user
    else
      create_new_user_with_account
    end
  end
  
  def handle_existing_user
    @account_user = @user.account_users.first
    
    if @account_user&.confirmed?
      raise ActiveRecord::RecordInvalid.new(@user.tap do |u|
        u.errors.add(:email_address, "is already registered. Please log in.")
      end)
    elsif @account_user
      # Resend confirmation for unconfirmed account
      @account_user.generate_confirmation_token
      @account_user.save!
      @confirmation_resent = true
      @account = @account_user.account
    else
      # Edge case: user exists but no account (shouldn't happen)
      create_account_for_existing_user
    end
  end
  
  def create_new_user_with_account
    @user.save!(validate: false) # Skip password validation
    create_personal_account
    create_account_user
  end
  
  def create_account_for_existing_user
    create_personal_account
    create_account_user
  end
  
  def create_personal_account
    @account = Account.create!(
      name: "#{@email} - Personal Account",
      account_type: :personal
    )
  end
  
  def create_account_user
    @account_user = AccountUser.create!(
      account: @account,
      user: @user,
      role: 'owner'
    )
  end
  
  def send_confirmation_email
    @account_user.send_confirmation_email
  end
end
```

### 2. Confirmation Service
```ruby
# app/services/confirmation_service.rb
class ConfirmationService
  attr_reader :account_user, :user, :account
  
  def initialize(token)
    @token = token
  end
  
  def execute
    find_account_user
    return self unless @account_user
    
    ActiveRecord::Base.transaction do
      confirm_account_user
      set_default_account
    end
    
    self
  rescue ActiveRecord::RecordNotFound
    @error = "Invalid or expired confirmation link"
    self
  end
  
  def success?
    @error.nil? && @account_user&.confirmed?
  end
  
  def already_confirmed?
    @already_confirmed
  end
  
  def error
    @error
  end
  
  private
  
  def find_account_user
    @account_user = AccountUser.find_by!(confirmation_token: @token)
    @user = @account_user.user
    @account = @account_user.account
    
    if @account_user.confirmed?
      @already_confirmed = true
    end
  rescue ActiveRecord::RecordNotFound
    @error = "Invalid or expired confirmation link"
  end
  
  def confirm_account_user
    return if @already_confirmed
    @account_user.confirm!
  end
  
  def set_default_account
    if @user.default_account.nil?
      @user.update!(default_account: @account)
    end
  end
end
```

## Controller Updates

### 1. RegistrationsController Changes
```ruby
# app/controllers/registrations_controller.rb
class RegistrationsController < ApplicationController
  # ... existing code ...
  
  def create
    service = RegistrationService.new(params[:email_address])
    service.execute
    
    if service.success?
      message = service.confirmation_resent? ? 
        "Confirmation email resent. Please check your inbox." :
        "Please check your email to confirm your account."
      redirect_to check_email_path, notice: message
    else
      redirect_to signup_path, inertia: { errors: service.errors }
    end
  end
  
  def confirm_email
    service = ConfirmationService.new(params[:token])
    service.execute
    
    if service.already_confirmed?
      redirect_to login_path, notice: "Email already confirmed. Please log in."
    elsif service.success?
      session[:pending_password_user_id] = service.user.id
      redirect_to set_password_path, notice: "Email confirmed! Please set your password."
    else
      redirect_to signup_path, alert: service.error
    end
  end
  
  # ... rest remains similar ...
end
```

### 2. ApplicationController Updates
```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Authentication
  include AccountScoping
  
  # ... existing code ...
end
```

### 3. New Concern: AccountScoping
```ruby
# app/controllers/concerns/account_scoping.rb
module AccountScoping
  extend ActiveSupport::Concern
  
  included do
    helper_method :current_account, :current_account_user
  end
  
  private
  
  def current_account
    @current_account ||= current_user&.default_account
  end
  
  def current_account_user
    @current_account_user ||= current_user&.account_users&.find_by(account: current_account)
  end
  
  def require_account
    redirect_to account_required_path unless current_account
  end
  
  def authorize_account_access
    unless current_account_user&.confirmed?
      redirect_to unauthorized_path, alert: "You don't have access to this account"
    end
  end
end
```

## Migration Strategy

### Phase 1: Create New Tables
```ruby
# db/migrate/001_create_accounts.rb
class CreateAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :accounts do |t|
      t.string :name, null: false
      t.integer :account_type, null: false, default: 0
      t.string :slug
      t.jsonb :settings, default: {}
      t.timestamps
      
      t.index :slug, unique: true
      t.index :account_type
      t.index :created_at
    end
  end
end

# db/migrate/002_create_account_users.rb
class CreateAccountUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :account_users do |t|
      t.references :account, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :role, null: false, default: 'owner'
      t.string :confirmation_token
      t.datetime :confirmation_sent_at
      t.datetime :confirmed_at
      t.datetime :invited_at
      t.string :invited_by_id
      t.timestamps
      
      t.index [:account_id, :user_id], unique: true
      t.index :confirmation_token, unique: true
      t.index :user_id
      t.index [:account_id, :role]
      t.index :confirmed_at
    end
    
    add_reference :users, :default_account, foreign_key: { to_table: :accounts }
    add_column :users, :migrated_to_account_users, :boolean, default: false
  end
end
```

### Phase 2: Data Migration
```ruby
# db/migrate/003_migrate_existing_users_to_accounts.rb
class MigrateExistingUsersToAccounts < ActiveRecord::Migration[8.0]
  def up
    User.find_each do |user|
      next if user.migrated_to_account_users
      
      ActiveRecord::Base.transaction do
        # Create personal account
        account = Account.create!(
          name: "#{user.email_address} - Personal Account",
          account_type: :personal,
          created_at: user.created_at,
          updated_at: user.updated_at
        )
        
        # Create account_user relationship
        account_user = AccountUser.create!(
          account: account,
          user: user,
          role: 'owner',
          confirmation_token: user.confirmation_token,
          confirmation_sent_at: user.confirmation_sent_at,
          confirmed_at: user.confirmed_at,
          created_at: user.created_at,
          updated_at: user.updated_at
        )
        
        # Set default account
        user.update_columns(
          default_account_id: account.id,
          migrated_to_account_users: true
        )
      end
    end
  end
  
  def down
    AccountUser.destroy_all
    Account.destroy_all
    User.update_all(default_account_id: nil, migrated_to_account_users: false)
  end
end
```

### Phase 3: Cleanup (After Verification)
```ruby
# db/migrate/004_remove_confirmation_fields_from_users.rb
# Run this migration only after verifying all data is migrated
class RemoveConfirmationFieldsFromUsers < ActiveRecord::Migration[8.0]
  def change
    remove_column :users, :confirmation_token, :string
    remove_column :users, :confirmation_sent_at, :datetime
    remove_column :users, :confirmed_at, :datetime
    remove_column :users, :migrated_to_account_users, :boolean
  end
end
```

## Email Template Updates

### New AccountMailer
```ruby
# app/mailers/account_mailer.rb
class AccountMailer < ApplicationMailer
  def confirmation(account_user)
    @account_user = account_user
    @user = account_user.user
    @account = account_user.account
    @confirmation_url = email_confirmation_url(token: account_user.confirmation_token)
    
    mail(
      to: @user.email_address,
      subject: "Confirm your email address for #{@account.name}"
    )
  end
  
  def team_invitation(account_user)
    @account_user = account_user
    @user = account_user.user
    @account = account_user.account
    @inviter = account_user.invited_by
    @confirmation_url = accept_invitation_url(token: account_user.confirmation_token)
    
    mail(
      to: @user.email_address,
      subject: "You've been invited to join #{@account.name}"
    )
  end
end
```

## Testing Strategy

### 1. Model Tests
```ruby
# test/models/account_test.rb
class AccountTest < ActiveSupport::TestCase
  test "personal accounts can only have one user" do
    account = accounts(:personal)
    user1 = users(:confirmed)
    user2 = users(:other)
    
    AccountUser.create!(account: account, user: user1, role: 'owner')
    
    assert_raises(ActiveRecord::RecordInvalid) do
      AccountUser.create!(account: account, user: user2, role: 'owner')
    end
  end
  
  test "team accounts can have multiple users" do
    account = accounts(:team)
    user1 = users(:confirmed)
    user2 = users(:other)
    
    assert_difference 'AccountUser.count', 2 do
      AccountUser.create!(account: account, user: user1, role: 'owner')
      AccountUser.create!(account: account, user: user2, role: 'member')
    end
  end
end

# test/models/account_user_test.rb
class AccountUserTest < ActiveSupport::TestCase
  test "generates confirmation token on create" do
    account_user = AccountUser.create!(
      account: accounts(:personal),
      user: users(:unconfirmed),
      role: 'owner'
    )
    
    assert_not_nil account_user.confirmation_token
    assert_not_nil account_user.confirmation_sent_at
  end
  
  test "confirm! updates confirmation fields" do
    account_user = account_users(:unconfirmed)
    
    account_user.confirm!
    
    assert account_user.confirmed?
    assert_nil account_user.confirmation_token
    assert_not_nil account_user.confirmed_at
  end
end
```

### 2. Service Tests
```ruby
# test/services/registration_service_test.rb
class RegistrationServiceTest < ActiveSupport::TestCase
  test "creates user, account, and account_user for new registration" do
    assert_difference ['User.count', 'Account.count', 'AccountUser.count'], 1 do
      service = RegistrationService.new("newuser@example.com")
      service.execute
      
      assert service.success?
      assert_not_nil service.user
      assert_not_nil service.account
      assert_not_nil service.account_user
    end
  end
  
  test "resends confirmation for existing unconfirmed user" do
    user = users(:unconfirmed)
    
    assert_no_difference ['User.count', 'Account.count', 'AccountUser.count'] do
      service = RegistrationService.new(user.email_address)
      service.execute
      
      assert service.success?
      assert service.confirmation_resent?
    end
  end
  
  test "prevents duplicate registration for confirmed user" do
    user = users(:confirmed)
    
    service = RegistrationService.new(user.email_address)
    service.execute
    
    assert_not service.success?
    assert_includes service.errors[:email_address], "is already registered"
  end
end
```

### 3. Integration Tests
```ruby
# test/integration/account_signup_flow_test.rb
class AccountSignupFlowTest < ActionDispatch::IntegrationTest
  test "complete signup flow with account creation" do
    # Submit email
    assert_difference ['User.count', 'Account.count', 'AccountUser.count'], 1 do
      post signup_path, params: { email_address: "newuser@example.com" }
    end
    assert_redirected_to check_email_path
    
    # Get created records
    user = User.last
    account = Account.last
    account_user = AccountUser.last
    
    # Verify account setup
    assert_equal "newuser@example.com - Personal Account", account.name
    assert account.personal?
    assert_equal 'owner', account_user.role
    assert_not account_user.confirmed?
    
    # Confirm email
    get email_confirmation_path(token: account_user.confirmation_token)
    assert_redirected_to set_password_path
    
    # Verify confirmation
    account_user.reload
    assert account_user.confirmed?
    
    # Set password
    patch set_password_path, params: {
      password: "password123",
      password_confirmation: "password123"
    }
    assert_redirected_to root_path
    
    # Verify login works
    post login_path, params: {
      email_address: "newuser@example.com",
      password: "password123"
    }
    assert_redirected_to root_path
  end
end
```

## Implementation Checklist

### Phase 1: Foundation (Day 1-2)
- [ ] Create Account model and migration
- [ ] Create AccountUser model and migration
- [ ] Update User model associations
- [ ] Create database constraints and triggers
- [ ] Write model unit tests
- [ ] Verify all model validations work

### Phase 2: Services (Day 2-3)
- [ ] Implement RegistrationService
- [ ] Implement ConfirmationService
- [ ] Create AccountMailer
- [ ] Update email templates
- [ ] Write service tests
- [ ] Test email sending in development

### Phase 3: Controllers (Day 3-4)
- [ ] Update RegistrationsController
- [ ] Create AccountScoping concern
- [ ] Update ApplicationController
- [ ] Update routes if needed
- [ ] Write controller tests
- [ ] Test full flow manually

### Phase 4: Data Migration (Day 4-5)
- [ ] Create data migration for existing users
- [ ] Test migration on development data
- [ ] Create rollback plan
- [ ] Document migration process
- [ ] Prepare production migration checklist

### Phase 5: Frontend Updates (Day 5-6)
- [ ] Update registration flow UI (minimal changes)
- [ ] Update confirmation email templates
- [ ] Add account indicator to navigation (optional)
- [ ] Test all user flows
- [ ] Update any API responses

### Phase 6: Cleanup & Documentation (Day 6-7)
- [ ] Remove old confirmation fields from User (after verification)
- [ ] Update API documentation
- [ ] Update test fixtures
- [ ] Performance testing
- [ ] Security review
- [ ] Deploy to staging

## Security Considerations

1. **Token Security**
   - Confirmation tokens are now scoped to AccountUser
   - Tokens expire after 24 hours
   - Tokens are unique and cryptographically secure

2. **Data Isolation**
   - Account scoping prevents cross-account data access
   - Personal accounts enforced at database level
   - Role-based permissions ready for future implementation

3. **Session Management**
   - Sessions remain tied to User, not Account
   - Account switching will require additional implementation
   - Default account provides smooth UX

4. **Email Verification**
   - Each account relationship requires confirmation
   - Prevents account takeover via unverified emails
   - Clear audit trail via timestamps

## Performance Considerations

1. **Database Indexes**
   - Composite index on [account_id, user_id] for uniqueness
   - Individual indexes for common lookups
   - Partial indexes for confirmed/unconfirmed queries

2. **Query Optimization**
   - Use includes/joins to prevent N+1 queries
   - Scope queries to current account early
   - Cache current_account in request cycle

3. **Migration Performance**
   - Batch process existing users
   - Use update_columns to avoid callbacks
   - Consider running in background job for large datasets

## Potential Edge Cases

1. **Orphaned Records**
   - User exists without Account (handle in service)
   - Account exists without users (add cleanup job)
   - Unconfirmed AccountUser records (add expiration)

2. **Duplicate Registrations**
   - Same email, different casing (normalized in model)
   - Rapid successive signups (handled by find_or_initialize)
   - Confirmation token collisions (unique index)

3. **Migration Issues**
   - Users with nil confirmation fields
   - Users with invalid email addresses
   - Duplicate email addresses (shouldn't exist due to unique index)

## Future Enhancements

1. **Team Accounts**
   - Invitation system using AccountUser.invited_at
   - Role-based permissions (owner/admin/member)
   - Account switching UI

2. **Account Settings**
   - Custom account names/slugs
   - Account-level preferences
   - Billing integration

3. **Advanced Permissions**
   - Resource-level permissions
   - Custom roles
   - Audit logging

## Rollback Plan

If issues arise during deployment:

1. **Code Rollback**
   - Revert to previous git commit
   - Deploy previous version

2. **Database Rollback**
   - Migration includes down method
   - Can restore confirmation fields to User
   - Account tables can be dropped safely

3. **Data Recovery**
   - Confirmation tokens preserved during migration
   - User data remains intact
   - Sessions continue to work

## Success Metrics

- All existing users successfully migrated
- New registrations create proper account structure
- No increase in registration failures
- Email confirmation rate remains stable
- No performance degradation
- Zero data loss during migration