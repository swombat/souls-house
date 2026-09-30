# Account Management Implementation Plan (Rails Way Edition)

## Executive Summary

This revised plan implements multi-tenant account management following Rails conventions and DHH's philosophy. The solution eliminates service objects, removes SQL constraints, and uses Rails associations for authorization. Business logic lives in models with strategic use of concerns for shared behavior.

## Core Philosophy

1. **Fat models, skinny controllers** - Business logic belongs in models
2. **Rails validations only** - No custom SQL constraints
3. **Authorization through associations** - Use `current_user.accounts` for natural scoping
4. **Concerns for shared behavior** - Extract common patterns without over-abstraction
5. **Convention over configuration** - Follow Rails patterns, don't fight them

## Architecture Overview

### Key Changes from Original Plan
- ❌ **REMOVED**: Service objects (RegistrationService, ConfirmationService)
- ❌ **REMOVED**: SQL database constraints and triggers
- ❌ **REMOVED**: Row-level database security patterns
- ✅ **ADDED**: Business logic methods in User and AccountUser models
- ✅ **ADDED**: Confirmable concern for shared confirmation behavior
- ✅ **ADDED**: Authorization through Rails associations

### Data Flow
```
User Registration:
Controller (thin) → User.register! (business logic) → Creates Account + AccountUser → Send email

Confirmation:
Controller (thin) → AccountUser.confirm_by_token! → Updates state → Controller redirects
```

## Database Schema (Rails Validations Only)

### 1. Accounts Table
```ruby
class CreateAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :accounts do |t|
      t.string :name, null: false
      t.integer :account_type, null: false, default: 0  # enum: personal/team
      t.string :slug
      t.jsonb :settings, default: {}
      t.timestamps
      
      t.index :slug, unique: true
      t.index :account_type
    end
  end
end
```

### 2. Account Users Table
```ruby
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
      t.references :invited_by, foreign_key: { to_table: :users }
      t.timestamps
      
      t.index [:account_id, :user_id], unique: true
      t.index :confirmation_token, unique: true
      t.index :confirmed_at
    end
  end
end
```

### 3. Update Users Table
```ruby
class AddAccountFieldsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_reference :users, :default_account, foreign_key: { to_table: :accounts }
    # Temporary flag for migration tracking
    add_column :users, :migrated_to_accounts, :boolean, default: false
  end
end
```

## Model Implementation (The Rails Way)

### 1. Confirmable Concern
```ruby
# app/models/concerns/confirmable.rb
module Confirmable
  extend ActiveSupport::Concern
  
  included do
    before_create :generate_confirmation_token, if: :needs_confirmation?
    
    scope :confirmed, -> { where.not(confirmed_at: nil) }
    scope :unconfirmed, -> { where(confirmed_at: nil) }
    
    generates_token_for :email_confirmation, expires_in: 24.hours do
      # Include unique attributes to invalidate token if they change
      confirmable_attributes_for_token
    end
  end
  
  def confirmed?
    confirmed_at.present?
  end
  
  def confirm!
    return true if confirmed?
    
    update!(
      confirmed_at: Time.current,
      confirmation_token: nil
    )
  end
  
  def generate_confirmation_token
    self.confirmation_token = generate_token_for(:email_confirmation)
    self.confirmation_sent_at = Time.current
  end
  
  def resend_confirmation!
    generate_confirmation_token
    save!
    send_confirmation_email
  end
  
  private
  
  def needs_confirmation?
    confirmation_token.blank? && confirmed_at.blank?
  end
  
  # Override in including class to specify attributes
  def confirmable_attributes_for_token
    respond_to?(:email_address) ? email_address : id.to_s
  end
end
```

### 2. Account Model
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
  
  # Validations (Rails-only, no SQL constraints!)
  validates :name, presence: true
  validates :account_type, presence: true
  validate :enforce_personal_account_limit, if: :personal?
  
  # Callbacks
  before_validation :set_default_name, on: :create
  before_validation :generate_slug, on: :create
  
  # Scopes
  scope :personal, -> { where(account_type: :personal) }
  scope :team, -> { where(account_type: :team) }
  
  # Business Logic Methods
  def add_user!(user, role: 'member', skip_confirmation: false)
    account_user = account_users.find_or_initialize_by(user: user)
    
    if account_user.persisted?
      account_user.resend_confirmation! unless account_user.confirmed?
      account_user
    else
      account_user.role = role
      account_user.skip_confirmation = skip_confirmation
      account_user.save!
      account_user
    end
  end
  
  def personal_account_for?(user)
    personal? && owner == user
  end
  
  private
  
  def enforce_personal_account_limit
    if personal? && account_users.count > 1
      errors.add(:base, "Personal accounts can only have one user")
    end
  end
  
  def set_default_name
    self.name ||= "Account #{SecureRandom.hex(4)}"
  end
  
  def generate_slug
    self.slug ||= name.parameterize if name.present?
    
    # Ensure uniqueness
    if Account.exists?(slug: slug)
      self.slug = "#{slug}-#{SecureRandom.hex(4)}"
    end
  end
end
```

### 3. AccountUser Model
```ruby
# app/models/account_user.rb
class AccountUser < ApplicationRecord
  include Confirmable
  
  # Constants
  ROLES = %w[owner admin member].freeze
  
  # Attributes
  attr_accessor :skip_confirmation
  
  # Associations
  belongs_to :account
  belongs_to :user
  belongs_to :invited_by, class_name: 'User', optional: true
  
  # Validations (Rails-only!)
  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { 
    scope: :account_id,
    message: "is already a member of this account" 
  }
  validate :enforce_personal_account_role
  validate :enforce_single_owner_per_personal_account
  
  # Callbacks
  after_create :send_confirmation_email, unless: :skip_confirmation
  after_create :set_user_default_account
  
  # Scopes
  scope :owners, -> { where(role: 'owner') }
  scope :admins, -> { where(role: ['owner', 'admin']) }
  
  # Class Methods
  def self.confirm_by_token!(token)
    account_user = find_by!(confirmation_token: token)
    account_user.confirm!
    account_user
  rescue ActiveRecord::RecordNotFound
    raise ActiveSupport::MessageVerifier::InvalidSignature
  end
  
  # Instance Methods
  def owner?
    role == 'owner'
  end
  
  def admin?
    role.in?(['owner', 'admin'])
  end
  
  def can_manage?
    owner? || admin?
  end
  
  def send_confirmation_email
    if invited_by_id.present?
      AccountMailer.team_invitation(self).deliver_later
    else
      AccountMailer.confirmation(self).deliver_later
    end
  end
  
  private
  
  def confirmable_attributes_for_token
    "#{account_id}-#{user_id}-#{user.email_address}"
  end
  
  def enforce_personal_account_role
    if account&.personal? && role != 'owner'
      errors.add(:role, "must be owner for personal accounts")
    end
  end
  
  def enforce_single_owner_per_personal_account
    if account&.personal? && account.account_users.where.not(id: id).exists?
      errors.add(:base, "Personal accounts can only have one user")
    end
  end
  
  def set_user_default_account
    if user.default_account.nil?
      user.update_column(:default_account_id, account_id)
    end
  end
  
  def needs_confirmation?
    !skip_confirmation && super
  end
end
```

### 4. Updated User Model
```ruby
# app/models/user.rb
class User < ApplicationRecord
  has_secure_password validations: false
  has_many :sessions, dependent: :destroy
  
  # Account associations
  has_many :account_users, dependent: :destroy
  has_many :accounts, through: :account_users
  belongs_to :default_account, class_name: 'Account', optional: true
  has_one :personal_account_user, -> { joins(:account).where(accounts: { account_type: 0 }) }, 
          class_name: 'AccountUser'
  has_one :personal_account, through: :personal_account_user, source: :account
  
  normalizes :email_address, with: ->(e) { e.strip.downcase }
  
  validates :email_address, presence: true,
    uniqueness: { case_sensitive: false },
    format: { with: URI::MailTo::EMAIL_REGEXP }
  
  validates :password, confirmation: true,
    length: { in: 6..72 },
    if: :password_digest_changed?
  
  validates :password, presence: true, on: :update, if: :confirmed?
  
  # Keep password reset token (stays on User)
  generates_token_for :password_reset, expires_in: 2.hours do
    password_salt&.last(10)
  end
  
  # Business Logic Methods (not in a service!)
  def self.register!(email)
    transaction do
      user = find_or_initialize_by(email_address: email)
      
      if user.persisted?
        # Existing user - find or create their membership
        user.find_or_create_membership!
      else
        # New user - create with account
        user.save!(validate: false) # Skip password validation
        account = Account.create!(
          name: "#{email}'s Account",
          account_type: :personal
        )
        user.account_users.create!(
          account: account,
          role: 'owner'
        )
      end
      
      user
    end
  end
  
  def find_or_create_membership!
    # For existing users, ensure they have an account
    return personal_account_user if personal_account_user&.persisted?
    
    # Create personal account if missing
    account = Account.create!(
      name: "#{email_address}'s Account",
      account_type: :personal
    )
    
    account_users.create!(
      account: account,
      role: 'owner'
    )
  end
  
  # Backward compatibility during migration
  def confirmed?
    # Check if any account membership is confirmed
    account_users.confirmed.any?
  end
  
  def confirm!
    # Confirm the first unconfirmed account membership
    account_users.unconfirmed.first&.confirm!
  end
  
  def can_login?
    confirmed? && password_digest?
  end
  
  # Authorization helpers
  def member_of?(account)
    account_users.confirmed.where(account: account).exists?
  end
  
  def can_manage?(account)
    account_users.confirmed.admins.where(account: account).exists?
  end
  
  def owns?(account)
    account_users.confirmed.owners.where(account: account).exists?
  end
end
```

## Controller Implementation (Thin Controllers)

### 1. Updated RegistrationsController
```ruby
# app/controllers/registrations_controller.rb
class RegistrationsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create confirm_email set_password update_password check_email ]
  before_action :redirect_if_authenticated, only: [ :new ]
  before_action :load_pending_user, only: [ :set_password, :update_password ]

  def new
    render inertia: "registrations/signup"
  end

  def create
    user = User.register!(normalized_email)
    account_user = user.account_users.last
    
    if account_user.confirmed?
      redirect_to signup_path, inertia: {
        errors: { email_address: ["This email is already registered. Please log in."] }
      }
    else
      notice = account_user.confirmation_sent_at > 1.minute.ago ?
        "Please check your email to confirm your account." :
        "Confirmation email resent. Please check your inbox."
      redirect_to check_email_path, notice: notice
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to signup_path, inertia: { errors: e.record.errors.to_hash(true) }
  end

  def check_email
    render inertia: "registrations/check-email"
  end

  def confirm_email
    account_user = AccountUser.confirm_by_token!(params[:token])
    
    if account_user.user.password_digest?
      redirect_to login_path, notice: "Email confirmed! Please log in."
    else
      session[:pending_password_user_id] = account_user.user_id
      redirect_to set_password_path, notice: "Email confirmed! Please set your password."
    end
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    redirect_to signup_path, alert: "Invalid or expired confirmation link. Please sign up again."
  end

  def set_password
    return redirect_to login_path, alert: "Invalid request." if @user&.password_digest?
    render inertia: "registrations/set-password", props: { email: @user.email_address }
  end

  def update_password
    if @user.update(password_params)
      session.delete(:pending_password_user_id)
      start_new_session_for @user
      redirect_to after_authentication_url, notice: "Account setup complete! Welcome!"
    else
      redirect_to set_password_path, inertia: { errors: @user.errors.to_hash(true) }
    end
  end

  private

  def normalized_email
    params[:email_address]&.strip&.downcase
  end

  def redirect_if_authenticated
    redirect_to root_path, alert: "You are already signed in." if authenticated?
  end

  def load_pending_user
    @user = User.find_by(id: session[:pending_password_user_id])
    redirect_to login_path, alert: "Invalid request." unless @user
  end

  def password_params
    params.permit(:password, :password_confirmation)
  end
end
```

### 2. New AccountScoping Concern
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
    @current_account_user ||= if current_account && current_user
      current_user.account_users.confirmed.find_by(account: current_account)
    end
  end
  
  def require_account
    redirect_to account_required_path unless current_account
  end
  
  # Authorization through associations - The Rails Way!
  def authorize_account_resource(resource)
    # Example: @project = current_user.accounts.find(params[:account_id]).projects.find(params[:id])
    # This naturally scopes to accounts the user has access to
    unless resource && current_user.member_of?(resource.account)
      redirect_to unauthorized_path, alert: "You don't have access to this resource"
    end
  end
  
  # For loading account-scoped resources
  def current_account_scope
    # Use this for loading resources
    # Example: @projects = current_account_scope.projects
    current_user.accounts.find(current_account.id)
  rescue ActiveRecord::RecordNotFound
    redirect_to unauthorized_path, alert: "You don't have access to this account"
  end
end
```

### 3. ApplicationController Update
```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Authentication
  include AccountScoping  # Add this
  
  # Existing code...
end
```

## Mailer Implementation

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
      subject: "Confirm your email address"
    )
  end
  
  def team_invitation(account_user)
    @account_user = account_user
    @user = account_user.user
    @account = account_user.account
    @inviter = account_user.invited_by
    @confirmation_url = email_confirmation_url(token: account_user.confirmation_token)
    
    mail(
      to: @user.email_address,
      subject: "You've been invited to join #{@account.name}"
    )
  end
end
```

## Data Migration (Simple and Rails-y)

```ruby
# db/migrate/xxx_migrate_existing_users_to_accounts.rb
class MigrateExistingUsersToAccounts < ActiveRecord::Migration[8.0]
  def up
    User.find_each do |user|
      next if user.migrated_to_accounts
      
      ActiveRecord::Base.transaction do
        # Create personal account
        account = Account.create!(
          name: "#{user.email_address}'s Account",
          account_type: :personal,
          created_at: user.created_at
        )
        
        # Create account_user with existing confirmation data
        AccountUser.create!(
          account: account,
          user: user,
          role: 'owner',
          confirmation_token: user.confirmation_token,
          confirmation_sent_at: user.confirmation_sent_at,
          confirmed_at: user.confirmed_at,
          created_at: user.created_at
        )
        
        # Set default account
        user.update_columns(
          default_account_id: account.id,
          migrated_to_accounts: true
        )
      end
    end
  end
  
  def down
    # Restore confirmation fields to users before dropping account tables
    AccountUser.includes(:user).find_each do |au|
      au.user.update_columns(
        confirmation_token: au.confirmation_token,
        confirmation_sent_at: au.confirmation_sent_at,
        confirmed_at: au.confirmed_at
      )
    end
    
    User.update_all(default_account_id: nil, migrated_to_accounts: false)
    AccountUser.destroy_all
    Account.destroy_all
  end
end
```

## Testing Strategy (Rails Testing Patterns)

### Model Tests
```ruby
# test/models/account_test.rb
class AccountTest < ActiveSupport::TestCase
  test "personal accounts validate single user limit" do
    account = Account.create!(name: "Personal", account_type: :personal)
    user1 = users(:one)
    user2 = users(:two)
    
    account.add_user!(user1, role: 'owner')
    
    assert_raises(ActiveRecord::RecordInvalid) do
      account.add_user!(user2, role: 'owner')
    end
  end
  
  test "team accounts allow multiple users" do
    account = Account.create!(name: "Team", account_type: :team)
    
    assert_nothing_raised do
      account.add_user!(users(:one), role: 'owner')
      account.add_user!(users(:two), role: 'member')
    end
  end
end

# test/models/user_test.rb  
class UserTest < ActiveSupport::TestCase
  test "register! creates user, account, and membership" do
    assert_difference ['User.count', 'Account.count', 'AccountUser.count'] do
      user = User.register!("new@example.com")
      assert user.persisted?
      assert user.personal_account.present?
      assert user.personal_account_user.present?
    end
  end
  
  test "register! handles existing unconfirmed user" do
    existing = User.create!(email_address: "existing@example.com")
    
    assert_no_difference 'User.count' do
      user = User.register!("existing@example.com")
      assert_equal existing, user
    end
  end
end
```

### Integration Tests
```ruby
# test/integration/account_registration_flow_test.rb
class AccountRegistrationFlowTest < ActionDispatch::IntegrationTest
  test "complete registration flow" do
    # Register
    assert_difference ['User.count', 'Account.count', 'AccountUser.count'] do
      post signup_path, params: { email_address: "new@example.com" }
    end
    assert_redirected_to check_email_path
    
    # Confirm email
    account_user = AccountUser.last
    get email_confirmation_path(token: account_user.confirmation_token)
    assert_redirected_to set_password_path
    
    # Set password
    patch set_password_path, params: {
      password: "secret123",
      password_confirmation: "secret123"
    }
    assert_redirected_to root_path
    
    # Verify structures
    user = User.last
    assert user.confirmed?
    assert user.personal_account.present?
    assert_equal user, user.personal_account.owner
  end
end
```

## Architecture Documentation Updates

Update `/docs/architecture.md` with these principles:

```markdown
## Authorization Patterns

### The Rails Way
- **Association-based authorization**: Use `current_user.accounts.find(params[:id])` to naturally scope access
- **No row-level database security**: Authorization happens in Rails, not the database
- **Simple scoping**: Resources belong to accounts, check access through associations

Example:
```ruby
# Good - Rails associations handle authorization
@project = current_user.accounts.find(params[:account_id]).projects.find(params[:id])

# Bad - Manual permission checking
@project = Project.find(params[:id])
authorize! @project  # Don't do this
```

### Validation Philosophy
- **Rails validations only**: All validation logic lives in models
- **No SQL constraints**: Avoid vendor lock-in and maintain flexibility
- **Clear error messages**: Rails validations provide better user feedback

### Business Logic Placement
- **Models contain business logic**: User.register!, Account.add_user!
- **Controllers stay thin**: Only orchestrate, don't implement logic
- **No service objects**: They hide code smells and create unnecessary abstraction
- **Concerns for shared behavior**: Extract truly shared patterns, not premature abstractions
```

## Implementation Checklist

### Phase 1: Foundation (Day 1)
- [ ] Create Account model with Rails validations only
- [ ] Create AccountUser model with Confirmable concern
- [ ] Update User model with business logic methods
- [ ] Write model tests
- [ ] Verify all validations work at Rails level

### Phase 2: Controllers (Day 1-2)
- [ ] Update RegistrationsController to use User.register!
- [ ] Add AccountScoping concern
- [ ] Update ApplicationController
- [ ] Create AccountMailer
- [ ] Test full registration flow

### Phase 3: Migration (Day 2)
- [ ] Create migration for existing users
- [ ] Test migration locally
- [ ] Verify rollback works
- [ ] Document migration process

### Phase 4: Testing (Day 2-3)
- [ ] Complete model test coverage
- [ ] Write integration tests for flows
- [ ] Test authorization patterns
- [ ] Performance testing

### Phase 5: Deployment (Day 3)
- [ ] Deploy to staging
- [ ] Run migration
- [ ] Verify existing users work
- [ ] Monitor for issues
- [ ] Deploy to production

## Key Differences from Original Plan

1. **No Service Objects**: Business logic in `User.register!` and model methods
2. **No SQL Constraints**: Rails validations handle all business rules  
3. **Simpler Authorization**: Use associations like `current_user.accounts`
4. **Confirmable Concern**: Shared behavior without over-engineering
5. **Thin Controllers**: Controllers only coordinate, models do the work
6. **Rails Conventions**: Follow patterns Rails developers expect

## Success Metrics

- Zero service objects in codebase
- All validation at Rails level (no SQL constraints)
- Controllers under 50 lines each
- Business logic in appropriate models
- Clear, Rails-idiomatic code that any Rails developer can understand