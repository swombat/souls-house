# app/models/membership.rb

# IMPORTANT: Why Membership contains "complex" business logic
#
# This model intentionally combines membership, invitation, and confirmation logic
# in a single place rather than splitting into separate Membership, Invitation,
# and Confirmation models. This is a deliberate design choice that actually
# REDUCES complexity by:
#
# 1. **Single Source of Truth**: One record tracks a user's entire relationship
#    with an account from invitation through active membership. No need to
#    coordinate state across multiple models or worry about orphaned records.
#
# 2. **Natural State Machine**: A user's journey from invited → confirmed → active
#    member is a single state progression on one record. Splitting this would
#    require complex coordination between models and increase the chance of
#    inconsistent states.
#
# 3. **Simpler Queries**: Finding all pending invitations, active members, or
#    checking permissions requires querying just one table instead of joining
#    across multiple tables.
#
# 4. **Follows Rails Patterns**: This is exactly what ActiveRecord polymorphic
#    associations and STI were designed to avoid - unnecessary model proliferation.
#    The complexity here is domain complexity, not accidental complexity.
#
# Example of what the alternative would look like:
#   - Invitation model (tracks invite status, token, expiry)
#   - Membership model (tracks active memberships and roles)
#   - Confirmation model (tracks email confirmation state)
#   - Complex service objects to coordinate transitions between these models
#   - Risk of orphaned invitations when memberships are created
#   - Duplicate role tracking across Invitation and Membership
#
# The current approach keeps related concerns together, making the code easier
# to understand and maintain, even if the single model appears "complex" at
# first glance. This is cohesion, not coupling.

class Membership < ApplicationRecord

  include Confirmable,
          JsonAttributes,
          SyncAuthorizable,
          Broadcastable

  # Constants
  ROLES = %w[owner admin member].freeze

  # Attributes
  attr_accessor :skip_confirmation

  # Associations
  belongs_to :account
  belongs_to :user
  belongs_to :invited_by, class_name: "User", optional: true

  # Broadcasting configuration - when Membership changes, broadcast to parent account
  broadcasts_to :account

  # Track if we're being destroyed by parent
  attr_accessor :skip_owner_check

  # Validations (Rails-only!)
  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: {
    scope: :account_id,
    message: "is already a member of this account"
  }
  validate :enforce_personal_account_rules
  before_destroy :ensure_removable

  # Callbacks with proper naming
  before_create :set_invitation_details
  before_create :auto_confirm_if_skip_confirmation
  after_create_commit :send_invitation_email, if: :invitation?
  after_create_commit :send_confirmation_email, unless: -> { skip_confirmation || invitation? }
  after_update_commit :track_invitation_acceptance, if: :became_confirmed?
  after_commit :disconnect_app_cable, if: :lost_app_authority?
  after_commit -> { ReplyExpectation.refresh_for(user_id) }

  # Scopes
  scope :owners, -> { where(role: "owner") }
  scope :admins, -> { where(role: [ "owner", "admin" ]) }
  scope :members, -> { where(role: "member") }
  scope :pending_invitations, -> { where(confirmed_at: nil).where.not(invited_by_id: nil) }
  scope :accepted_invitations, -> { where.not(confirmed_at: nil).where.not(invited_by_id: nil) }

  # Default Json Serialization
  json_attributes :display_name, :status, :invitation?, :invitation_pending?, :email_address, :full_name, :confirmed?,
                  include: {
                    user: { only: [ :id, :email_address ], methods: [ :full_name ] },
                    invited_by: { only: [ :id ], methods: [ :full_name ] }
                  } do |json, options|
    json[:can_remove] = removable_by?(options[:current_user]) if options && options[:current_user]
  end

  def self.confirm_by_token!(token)
    raise ActiveSupport::MessageVerifier::InvalidSignature if token.nil?

    membership = find_by_token_for(:email_confirmation, token)
    raise ActiveSupport::MessageVerifier::InvalidSignature unless membership

    membership.confirm!
    membership
  end

  # Instance Methods
  def owner?
    role == "owner"
  end

  def admin?
    role.in?([ "owner", "admin" ])
  end

  def can_manage?
    owner? || admin?
  end

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
    return false unless account.manageable_by?(user)
    return false if self.user_id == user.id # Can't remove yourself
    return false if owner? && account.last_owner? # Can't remove last owner
    true
  end

  # Why a manager may not remove this membership, or nil when they may. The
  # web and API both show these words.
  def removal_refusal_for(user)
    return "Cannot remove the last owner" if owner? && account.last_owner?

    "You can't remove yourself from this account" if user_id == user&.id
  end

  def resend_invitation!
    return false unless invitation_pending?

    # Update invitation details
    self.invited_at = Time.current
    generate_confirmation_token

    # Save and send the email
    if save!
      send_invitation_email
      true
    end
  end

  def display_name
    if user.confirmed? && user.first_name.present?
      user.full_name
    else
      user.email_address
    end
  end

  def full_name
    user.full_name || "-"
  end

  def email_address
    user.email_address
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

  private

  # Losing confirmed membership ends the member's native-app authority here
  # (issue #94 B, step 6); their cable connections are dropped after commit.
  def lost_app_authority?
    destroyed? || (saved_change_to_confirmed_at? && confirmed_at.nil?)
  end

  def disconnect_app_cable
    AppSession.disconnect_cable_for(user)
  end

  def auto_confirm_if_skip_confirmation
    self.confirmed_at = Time.current if skip_confirmation
  end

  def confirmable_attributes_for_token
    "#{account_id}-#{user_id}-#{user.email_address}"
  end

  def enforce_personal_account_rules
    if account&.personal?
      errors.add(:role, "must be owner for personal accounts") if role != "owner"
      errors.add(:base, "Personal accounts can only have one user") if account.memberships.where.not(id: id).exists?
    end
  end

  def ensure_removable
    # Skip check if explicitly told to (e.g., when account is being destroyed)
    return if skip_owner_check

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

  def send_confirmation_email
    AccountMailer.confirmation(self).deliver_later
  end

  # Properly named callback method
  def became_confirmed?
    saved_change_to_confirmed_at? && confirmed_at.present?
  end

  def track_invitation_acceptance
    update_column(:invitation_accepted_at, Time.current) if invitation?
  end

  def needs_confirmation?
    !skip_confirmation && super
  end

end
