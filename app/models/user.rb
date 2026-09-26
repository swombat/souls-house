class User < ApplicationRecord

  include Authenticatable
  include JsonAttributes
  include SyncAuthorizable
  include Broadcastable

  # Profile delegation
  has_one :profile, dependent: :destroy
  accepts_nested_attributes_for :profile, update_only: false
  delegate :full_name, :avatar, :avatar_url, :timezone,
           :first_name, :last_name, :chat_colour, to: :profile, allow_nil: true

  # Account associations through memberships
  has_many :memberships, dependent: :destroy
  has_many :confirmed_memberships, -> { confirmed }, class_name: "Membership"
  has_many :accounts, through: :memberships
  has_many :confirmed_accounts, -> { enabled }, through: :confirmed_memberships, source: :account
  has_one :personal_membership, -> { joins(:account).where(accounts: { account_type: 0 }) },
          class_name: "Membership"
  has_one :personal_account, through: :personal_membership, source: :account

  # API keys for external access
  has_many :api_keys, dependent: :destroy
  has_many :device_streams, foreign_key: :subject_user_id, dependent: :destroy

  # Integrations
  has_one :oura_integration, dependent: :destroy
  has_many :connected_service_connections,
           class_name: "ServiceConnection",
           foreign_key: :connected_by_user_id,
           dependent: :restrict_with_error
  has_many :service_authorization_attempts, dependent: :destroy

  # Broadcasting configuration - automatically broadcasts to all associated accounts
  broadcasts_to :accounts

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address, presence: true,
    uniqueness: { case_sensitive: false },
    format: { with: URI::MailTo::EMAIL_REGEXP }

  after_create :ensure_membership_exists
  after_create :create_profile

  json_attributes :first_name, :last_name, :timezone, :full_name, :site_admin, :avatar_url, :initials, :preferences, :chat_colour, except: [ :password_digest, :password_reset_token, :password_reset_sent_at ]

  # Confirmation is now handled entirely by Membership
  def confirmed?
    # A user is confirmed if they have at least one confirmed account membership
    memberships.confirmed.any?
  end

  # Business Logic Methods (not in a service!)
  def self.register!(email)
    transaction do
      user = find_or_initialize_by(email_address: email)
      was_new_user = !user.persisted?

      if user.persisted?
        # Existing user - find or create their membership
        membership = user.find_or_create_membership!

        # If the user is not confirmed, resend confirmation
        if !user.confirmed?
          membership.resend_confirmation!
        end
      else
        # New user - validate email first, then create
        user.valid?
        if user.errors[:email_address].any?
          raise ActiveRecord::RecordInvalid.new(user)
        end

        user.save!(validate: false) # Skip password validation
        # The after_create callback will have created a Membership with confirmation
      end

      # Add a method to track if this was a new user
      user.define_singleton_method(:was_new_record?) { was_new_user }
      user
    end
  end

  def find_or_create_membership!
    # For existing users, ensure they have an account
    return personal_membership if personal_membership&.persisted?

    # Create personal account if missing
    account = Account.create!(
      name: "#{email_address}'s Account",
      account_type: :personal
    )

    # Create unconfirmed Membership
    memberships.create!(
      account: account,
      role: "owner"
    )
  end

  def default_account
    memberships.confirmed.includes(:account).first&.account
  end

  # For finding or creating invited users
  def self.find_or_invite(email_address)
    user = find_by(email_address: email_address)
    return user if user

    # Create user without validation (no password required for invitations)
    user = new(email_address: email_address)
    user.save!(validate: false)
    user
  end

  def oura_health_context
    oura_integration&.health_context
  end

  def oura_health_context_labeled
    oura_integration&.health_context_for(display_name)
  end

  def display_name
    full_name.presence || email_address
  end

  def site_admin
    return true if is_site_admin

    confirmed_accounts.where(is_site_admin: true).exists?
  end

  # Alias for site_admin method to match common Rails pattern
  alias_method :is_site_admin?, :site_admin

  # Handle delegation edge cases where profile might not exist yet
  def theme
    profile&.theme || "system"
  end

  def initials
    profile&.initials || "?"
  end

  def preferences
    profile&.preferences || {}
  end

  private

  def create_profile
    # Create a profile for the user with default theme
    build_profile(theme: "system").save!
  end

  def ensure_membership_exists
    # Ensure any User created gets a Membership
    return if memberships.exists?

    account = Account.create!(
      name: "#{email_address}'s Account",
      account_type: :personal
    )

    # Create unconfirmed Membership (will send confirmation email)
    memberships.create!(
      account: account,
      role: "owner"
    )
  end

end
