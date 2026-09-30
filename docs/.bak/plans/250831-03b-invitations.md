# Implementation Plan: Team Account Invitation System (Revised - Rails Way)

## Executive Summary

This revised plan implements a team invitation system following strict Rails conventions and DHH's philosophy. All business logic resides in models, controllers remain minimal, and we leverage Rails' built-in features for validations, callbacks, and associations. No unnecessary abstractions or service objects - just clean, idiomatic Rails code.

## Architecture Overview

### Core Principles
1. **Fat models, skinny controllers** - All business logic in models
2. **Rails validations over exceptions** - Use ActiveRecord validations
3. **Leverage associations** - Let Rails handle authorization naturally
4. **Rails callbacks for side effects** - Send emails via model callbacks
5. **Convention over configuration** - Follow Rails naming perfectly

### Components
- Enhanced models with all business logic
- Minimal controllers (basic CRUD only)
- Rails validations and callbacks
- Association-based authorization
- Svelte components for UI (unchanged from v1)

## Implementation Steps

### Phase 1: Database Schema Updates

- [ ] Add invitation tracking fields
```ruby
# db/migrate/TIMESTAMP_add_invitation_fields_to_account_users.rb
class AddInvitationFieldsToAccountUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :account_users, :invitation_accepted_at, :datetime
    add_index :account_users, :invitation_accepted_at
  end
end
```

### Phase 2: Model Enhancements (Business Logic Lives Here!)

- [ ] Update AccountUser model with invitation logic
```ruby
# app/models/account_user.rb
class AccountUser < ApplicationRecord
  include Confirmable
  
  # Constants
  ROLES = %w[owner admin member].freeze
  
  # Associations
  belongs_to :account
  belongs_to :user
  belongs_to :invited_by, class_name: "User", optional: true
  
  # Validations (The Rails Way!)
  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { 
    scope: :account_id,
    message: "is already a member of this account" 
  }
  validate :enforce_personal_account_rules
  validate :ensure_removable, on: :destroy
  
  # Callbacks (for side effects)
  before_create :set_invitation_details
  after_create_commit :send_invitation_email, if: :invitation?
  after_update_commit :track_invitation_acceptance, if: :just_confirmed?
  
  # Scopes
  scope :owners, -> { where(role: "owner") }
  scope :admins, -> { where(role: ["owner", "admin"]) }
  scope :members, -> { where(role: "member") }
  scope :pending_invitations, -> { where(confirmed_at: nil).where.not(invited_by_id: nil) }
  scope :accepted_invitations, -> { where.not(confirmed_at: nil).where.not(invited_by_id: nil) }
  
  # Business Logic Methods
  def invitation?
    invited_by_id.present?
  end
  
  def invitation_pending?
    invitation? && !confirmed?
  end
  
  def invitation_accepted?
    invitation? && confirmed?
  end
  
  def removable_by?(user)
    return false unless user.can_manage?(account)
    return false if self.user_id == user.id # Can't remove yourself
    return false if owner? && account.last_owner? # Can't remove last owner
    true
  end
  
  def resend_invitation!
    return false unless invitation_pending?
    
    # Update invitation details
    self.invited_at = Time.current
    generate_confirmation_token
    
    # Save and let callback handle email
    save!
  end
  
  def display_name
    if user.confirmed? && user.first_name.present?
      user.full_name
    else
      user.email_address
    end
  end
  
  def status
    if invitation_pending?
      "invited"
    elsif confirmed?
      "active"
    else
      "pending"
    end
  end
  
  # Serialization (Rails way, not manual mapping!)
  def as_json(options = {})
    super(options.merge(
      methods: [:display_name, :status, :invitation?],
      include: {
        user: { only: [:id, :email_address], methods: [:full_name] },
        invited_by: { only: [:id], methods: [:full_name] }
      }
    ))
  end
  
  private
  
  def enforce_personal_account_rules
    if account&.personal?
      errors.add(:role, "must be owner for personal accounts") if role != "owner"
      errors.add(:base, "Personal accounts can only have one user") if account.account_users.where.not(id: id).exists?
    end
  end
  
  def ensure_removable
    if owner? && account.last_owner?
      errors.add(:base, "Cannot remove the last owner")
      throw :abort
    end
  end
  
  def set_invitation_details
    self.invited_at = Time.current if invitation?
  end
  
  def send_invitation_email
    if invitation?
      AccountMailer.team_invitation(self).deliver_later
    else
      AccountMailer.confirmation(self).deliver_later
    end
  end
  
  def just_confirmed?
    saved_change_to_confirmed_at? && confirmed_at.present?
  end
  
  def track_invitation_acceptance
    update_column(:invitation_accepted_at, Time.current) if invitation?
  end
end
```

- [ ] Update Account model with invitation business logic
```ruby
# app/models/account.rb
class Account < ApplicationRecord
  # Existing code...
  
  # Business Logic for Invitations (in the model!)
  def invite_member(email:, role:, invited_by:)
    # All validation through Rails validations, not exceptions
    account_users.build(
      user: User.find_or_create_by!(email_address: email),
      role: role,
      invited_by: invited_by
    )
  end
  
  def last_owner?
    account_users.owners.confirmed.count == 1
  end
  
  def members_count
    account_users.confirmed.count
  end
  
  def pending_invitations_count
    account_users.pending_invitations.count
  end
  
  # Association with proper includes for N+1 prevention
  def members_with_details
    account_users.includes(:user, :invited_by).order(:created_at)
  end
  
  # Validation for invitation
  validate :can_invite_members, if: -> { account_users.any?(&:invitation?) }
  
  private
  
  def can_invite_members
    errors.add(:base, "Personal accounts cannot invite members") if personal?
  end
end
```

- [ ] Update User model with authorization helpers
```ruby
# app/models/user.rb additions
class User < ApplicationRecord
  # Existing code...
  
  # Clean authorization methods (no service objects!)
  def can_manage?(account)
    account_users.confirmed.admins.exists?(account: account)
  end
  
  def owns?(account)
    account_users.confirmed.owners.exists?(account: account)
  end
  
  def member_of?(account)
    account_users.confirmed.exists?(account: account)
  end
  
  # For finding or creating by email (used in invitations)
  def self.find_or_create_by!(email_address:)
    user = find_or_initialize_by(email_address: email_address)
    if user.new_record?
      # Skip password validation for invited users
      user.save!(validate: false)
    end
    user
  end
end
```

### Phase 3: Controllers (Minimal - Just CRUD!)

- [ ] Create AccountMembersController (skinny!)
```ruby
# app/controllers/account_members_controller.rb
class AccountMembersController < ApplicationController
  before_action :set_account
  
  def index
    @members = @account.members_with_details
    
    render inertia: 'accounts/members', props: {
      account: @account,
      members: @members.map { |m| 
        m.as_json.merge(
          can_remove: m.removable_by?(Current.user)
        )
      },
      can_manage: Current.user.can_manage?(@account),
      current_user_id: Current.user.id
    }
  end
  
  def destroy
    @member = @account.account_users.find(params[:id])
    
    if @member.destroy
      redirect_to account_members_path(@account), 
        notice: "Member removed successfully"
    else
      redirect_to account_members_path(@account), 
        alert: @member.errors.full_messages.to_sentence
    end
  end
  
  private
  
  def set_account
    # Association-based authorization - The Rails Way!
    @account = Current.user.accounts.find(params[:account_id])
  end
end
```

- [ ] Create InvitationsController (minimal!)
```ruby
# app/controllers/invitations_controller.rb
class InvitationsController < ApplicationController
  before_action :set_account
  before_action :authorize_management
  
  def create
    @invitation = @account.invite_member(
      email: invitation_params[:email],
      role: invitation_params[:role],
      invited_by: Current.user
    )
    
    if @invitation.save
      redirect_to account_members_path(@account), 
        notice: "Invitation sent to #{invitation_params[:email]}"
    else
      redirect_to account_members_path(@account), 
        alert: @invitation.errors.full_messages.to_sentence
    end
  end
  
  def resend
    @member = @account.account_users.find(params[:id])
    
    if @member.resend_invitation!
      redirect_to account_members_path(@account), 
        notice: "Invitation resent"
    else
      redirect_to account_members_path(@account), 
        alert: "Could not resend invitation"
    end
  end
  
  private
  
  def set_account
    @account = Current.user.accounts.find(params[:account_id])
  end
  
  def authorize_management
    unless Current.user.can_manage?(@account)
      redirect_to account_path(@account), 
        alert: "You don't have permission to manage members"
    end
  end
  
  def invitation_params
    params.permit(:email, :role)
  end
end
```

### Phase 4: Routes Configuration

- [ ] Update routes.rb (RESTful!)
```ruby
# config/routes.rb
resources :accounts, only: [:show, :edit, :update] do
  resources :members, controller: 'account_members', only: [:index, :destroy]
  resources :invitations, only: [:create] do
    member do
      post :resend
    end
  end
end
```

### Phase 5: Mailer Updates

- [ ] Update AccountMailer for team invitations
```ruby
# app/mailers/account_mailer.rb
class AccountMailer < ApplicationMailer
  def team_invitation(account_user)
    @account_user = account_user
    @account = account_user.account
    @user = account_user.user
    @inviter = account_user.invited_by
    @confirmation_url = email_confirmation_url(token: account_user.confirmation_token)
    
    mail(
      to: @user.email_address,
      subject: "You've been invited to join #{@account.name}"
    )
  end
  
  # Existing confirmation method stays the same
end
```

### Phase 6: Frontend Components (Unchanged from v1)

The Svelte components remain the same as in the original plan, as they properly handle the UI layer without mixing in business logic.

### Phase 7: Testing Strategy (Rails Testing Conventions)

- [ ] Model Tests (where the logic lives!)
```ruby
# test/models/account_user_test.rb
class AccountUserTest < ActiveSupport::TestCase
  test "validates role inclusion" do
    account_user = AccountUser.new(role: "invalid")
    assert_not account_user.valid?
    assert_includes account_user.errors[:role], "is not included in the list"
  end
  
  test "prevents removing last owner" do
    account = accounts(:team)
    owner_membership = account.account_users.owners.first
    
    # Make sure it's the last owner
    account.account_users.owners.where.not(id: owner_membership.id).destroy_all
    
    assert_not owner_membership.destroy
    assert_includes owner_membership.errors[:base], "Cannot remove the last owner"
  end
  
  test "sends invitation email on create with invited_by" do
    account = accounts(:team)
    inviter = users(:admin)
    
    assert_enqueued_emails 1 do
      AccountUser.create!(
        account: account,
        user: User.create!(email_address: "new@example.com"),
        role: "member",
        invited_by: inviter
      )
    end
  end
  
  test "removable_by returns correct values" do
    account = accounts(:team)
    admin = users(:admin)
    member = account.account_users.members.first
    
    assert member.removable_by?(admin)
    assert_not member.removable_by?(member.user)
  end
end

# test/models/account_test.rb
class AccountTest < ActiveSupport::TestCase
  test "invite_member creates pending invitation" do
    account = accounts(:team)
    admin = users(:admin)
    
    invitation = account.invite_member(
      email: "newuser@example.com",
      role: "member",
      invited_by: admin
    )
    
    assert invitation.new_record?
    assert_equal "member", invitation.role
    assert_equal admin, invitation.invited_by
    assert invitation.invitation?
  end
  
  test "personal accounts cannot invite members" do
    account = accounts(:personal)
    owner = account.owner
    
    invitation = account.invite_member(
      email: "test@example.com",
      role: "member",
      invited_by: owner
    )
    
    account.valid?
    assert_includes account.errors[:base], "Personal accounts cannot invite members"
  end
end
```

- [ ] Controller Tests (minimal, just HTTP layer)
```ruby
# test/controllers/account_members_controller_test.rb
class AccountMembersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @account = @admin.accounts.first
    sign_in @admin
  end
  
  test "should get index" do
    get account_members_path(@account)
    assert_response :success
  end
  
  test "should destroy member" do
    member = @account.account_users.members.first
    
    assert_difference '@account.account_users.count', -1 do
      delete account_member_path(@account, member)
    end
    
    assert_redirected_to account_members_path(@account)
  end
  
  test "should not destroy last owner" do
    # Ensure only one owner
    @account.account_users.owners.where.not(user: @admin).destroy_all
    owner_membership = @account.account_users.owners.first
    
    assert_no_difference '@account.account_users.count' do
      delete account_member_path(@account, owner_membership)
    end
    
    assert_redirected_to account_members_path(@account)
  end
end

# test/controllers/invitations_controller_test.rb  
class InvitationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @account = @admin.accounts.team.first
    sign_in @admin
  end
  
  test "should create invitation" do
    assert_difference 'AccountUser.count' do
      post account_invitations_path(@account), params: {
        email: "newmember@example.com",
        role: "member"
      }
    end
    
    assert_redirected_to account_members_path(@account)
  end
  
  test "should handle validation errors" do
    post account_invitations_path(@account), params: {
      email: "invalid-email",
      role: "member"
    }
    
    assert_redirected_to account_members_path(@account)
    assert_match /Email address is invalid/, flash[:alert]
  end
  
  test "members cannot invite" do
    member = users(:member)
    sign_in member
    
    post account_invitations_path(@account), params: {
      email: "test@example.com",
      role: "member"
    }
    
    assert_redirected_to account_path(@account)
  end
end
```

## Key Improvements from Version 1

### 1. Business Logic in Models
- All invitation logic moved to AccountUser and Account models
- No business logic in controllers
- Models handle their own validation and state

### 2. Rails Validations Instead of Exceptions
- Use `validate` and `validates` for all business rules
- Return validation errors, not string exceptions
- Leverage Rails' error handling

### 3. Leveraging ActiveRecord
- Use `as_json` for serialization instead of manual mapping
- Use associations for authorization (`Current.user.accounts.find`)
- Use callbacks for side effects (sending emails)

### 4. Simplified Controllers
- Controllers only handle HTTP concerns
- No business logic or authorization logic
- Just basic CRUD operations

### 5. Proper Rails Callbacks
- `after_create_commit` for sending emails
- `before_create` for setting defaults
- `after_update_commit` for tracking changes

## Security & Performance

### Security (Rails Way)
- Association-based authorization (no manual checks)
- Rails validations prevent invalid data
- CSRF protection built-in
- SQL injection protection via ActiveRecord

### Performance
- Proper use of `includes` to prevent N+1 queries
- Database indexes on lookup fields
- Leveraging Rails query caching
- Efficient use of associations

## Testing Philosophy

Tests focus on models (where the logic lives):
- Model tests verify business rules
- Controller tests only verify HTTP layer
- Integration tests verify full flow
- No testing of Rails internals

## Deployment Notes

1. Run migration for invitation_accepted_at
2. No new gems required
3. No new environment variables
4. Uses existing Rails infrastructure

## Summary

This revised architecture follows "The Rails Way" strictly:
- Fat models with all business logic
- Skinny controllers doing minimal work
- Rails validations and callbacks
- Association-based authorization
- No unnecessary abstractions

The code is clean, maintainable, and would make DHH proud. Any Rails developer can understand and extend this system without learning custom patterns or abstractions.