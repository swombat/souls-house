class Account < ApplicationRecord

  include JsonAttributes
  include SyncAuthorizable
  include Broadcastable

  # Broadcasting configuration
  broadcasts_to :all # Admin collection
  skip_broadcasts_on_destroy :memberships, :agents, :chats, :whiteboards

  # Enums
  enum :account_type, { personal: 0, team: 1 }

  AI_PROVIDERS = {
    openrouter: {
      env: "OPENROUTER_API_KEY",
      credentials: %i[ai openrouter api_token],
      ruby_llm: :openrouter_api_key
    },
    anthropic: {
      env: "ANTHROPIC_API_KEY",
      credentials: %i[ai claude api_token],
      ruby_llm: :anthropic_api_key
    },
    openai: {
      env: "OPENAI_API_KEY",
      credentials: %i[ai open_ai api_token],
      ruby_llm: :openai_api_key
    },
    gemini: {
      env: "GEMINI_API_KEY",
      credentials: %i[ai gemini api_token],
      ruby_llm: :gemini_api_key
    },
    xai: {
      env: "XAI_API_KEY",
      credentials: %i[ai xai api_token],
      ruby_llm: :xai_api_key
    },
    zai: { env: "ZAI_API_KEY", credentials: %i[ai zai api_token] },
    moonshot: { env: "MOONSHOT_API_KEY", credentials: %i[ai moonshot api_token] },
    minimax: { env: "MINIMAX_API_KEY", credentials: %i[ai minimax api_token] }
  }.freeze
  AI_CREDENTIAL_ATTRIBUTES = [
    :use_system_ai_credentials,
    *AI_PROVIDERS.keys.map { |provider| "#{provider}_api_key".to_sym }
  ].freeze

  # Associations
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_one :owner_membership, -> { where(role: "owner") },
          class_name: "Membership"
  has_one :owner, through: :owner_membership, source: :user
  has_many :chats, dependent: :destroy
  has_many :agents, dependent: :destroy
  has_many :notices, dependent: :destroy
  has_many :api_keys, dependent: :destroy
  has_many :metered_action_events, dependent: :destroy
  has_many :whiteboards, dependent: :destroy
  has_many :service_connections, dependent: :destroy
  has_many :service_authorization_attempts, dependent: :destroy
  has_one :github_integration
  has_one :x_integration

  # Validations (Rails-only, no SQL constraints!)
  validates :name, presence: true
  validates :account_type, presence: true
  validate :enforce_personal_account_limit, if: :personal?
  validate :can_invite_members, if: -> { memberships.any?(&:invitation?) }

  # Callbacks
  before_validation :set_default_name, on: :create
  before_validation :generate_slug, on: :create
  before_destroy :mark_memberships_for_skip_check, prepend: true

  # Scopes
  scope :personal, -> { where(account_type: :personal) }
  scope :team, -> { where(account_type: :team) }
  scope :enabled, -> { where(disabled_at: nil) }
  scope :disabled, -> { where.not(disabled_at: nil) }

  encrypts :github_pat
  encrypts :openrouter_api_key
  encrypts :anthropic_api_key
  encrypts :openai_api_key
  encrypts :gemini_api_key
  encrypts :xai_api_key
  encrypts :zai_api_key
  encrypts :moonshot_api_key
  encrypts :minimax_api_key

  # Authorization scope for SyncChannel - Account is special, it IS the account
  def self.accessible_by(user)
    return none unless user
    return all if user.site_admin
    user.confirmed_accounts.enabled
  end

  json_attributes :personal?, :team?, :active?, :disabled, :is_site_admin, :name, :github_login,
                  :use_system_ai_credentials,
                  except: [ :github_pat, *AI_PROVIDERS.keys.map { |provider| "#{provider}_api_key" } ]

  # Business Logic Methods
  def add_user!(user, role: "member", skip_confirmation: false)
    membership = memberships.find_or_initialize_by(user: user)

    if membership.persisted?
      membership.resend_confirmation! unless membership.confirmed?
      membership
    else
      membership.role = role
      membership.skip_confirmation = skip_confirmation
      membership.save!
      membership
    end
  end

  # Business Logic for Invitations
  def invite_member(email:, role:, invited_by:)
    memberships.build(
      user: User.find_or_invite(email),
      role: role,
      invited_by: invited_by
    )
  end

  def last_owner?
    memberships.owners.confirmed.count == 1
  end

  def members_count
    memberships.confirmed.count
  end

  def active?
    !disabled? && members_count > 0
  end

  def disabled?
    disabled_at.present?
  end

  def disable!
    update!(disabled_at: Time.current) unless disabled?
  end

  def enable!
    update!(disabled_at: nil) if disabled?
  end

  def pending_invitations_count
    memberships.pending_invitations.count
  end

  # Association with proper includes for N+1 prevention
  def members_with_details
    memberships.includes(:user, :invited_by).order(:created_at)
  end

  def personal_account_for?(user)
    personal? && owner == user
  end

  def make_personal!
    return unless team? && memberships.count == 1

    membership = memberships.first
    transaction do
      membership.update!(role: :owner)
      update!(account_type: :personal, name: "#{membership.user.email_address}'s Account")
    end
  end

  def make_team!(name)
    return unless personal?
    update!(account_type: :team, name: name)
  end

  def can_be_personal?
    team? && memberships.count == 1
  end

  def name
    if personal? && default_personal_name? && owner&.full_name.present?
      "#{owner.full_name}'s Account"
    else
      super()
    end
  end

  def users_count
    memberships.count
  end

  def members_count
    memberships.confirmed.count
  end

  def github_commits_context
    github_integration&.commits_context
  end

  def ai_api_key(provider)
    provider = provider.to_sym
    config = AI_PROVIDERS.fetch(provider)
    configured_key = public_send("#{provider}_api_key").presence
    return configured_key if configured_key
    return unless use_system_ai_credentials?

    ruby_llm_key = RubyLLM.config.public_send(config[:ruby_llm]) if config[:ruby_llm]
    ruby_llm_key.presence ||
      Rails.application.credentials.dig(*config.fetch(:credentials)).presence ||
      ENV[config.fetch(:env)].presence
  end

  def ai_provider_keys
    AI_PROVIDERS.filter_map do |provider, config|
      value = ai_api_key(provider)
      [ config.fetch(:env), value ] if value.present? && !value.start_with?("<")
    end.to_h
  end

  def ai_api_keys_configured
    AI_PROVIDERS.keys.index_with { |provider| public_send("#{provider}_api_key").present? }
  end

  def saved_ai_credentials_change?
    (saved_changes.keys.map(&:to_sym) & AI_CREDENTIAL_ATTRIBUTES).any?
  end

  def ruby_llm_context
    RubyLLM.context do |config|
      config.openrouter_api_key = ai_api_key(:openrouter)
      config.anthropic_api_key = ai_api_key(:anthropic)
      config.openai_api_key = ai_api_key(:openai)
      config.gemini_api_key = ai_api_key(:gemini)
      config.xai_api_key = ai_api_key(:xai)
    end
  end

  alias_method :active, :active?
  alias_method :disabled, :disabled?

  # Authorization methods - following DHH's "fat models, skinny controllers" principle
  def manageable_by?(user)
    return false unless user
    return true if user.site_admin
    # Confirmed account members are treated as trusted collaborators.
    memberships.confirmed.exists?(user: user)
  end

  def ai_credentials_manageable_by?(user)
    return false unless user
    return true if user.site_admin

    memberships.confirmed.admins.exists?(user: user)
  end

  def service_credentials_manageable_by?(user)
    return false unless user
    return true if user.site_admin

    memberships.confirmed.admins.exists?(user: user)
  end

  def owned_by?(user)
    return false unless user
    return true if user.site_admin
    memberships.confirmed.owners.exists?(user: user)
  end

  def accessible_by?(user)
    return false unless user
    return true if user.site_admin
    memberships.confirmed.exists?(user: user)
  end

  # Custom error for authorization failures
  class NotAuthorized < StandardError; end

  private

  def enforce_personal_account_limit
    if personal? && memberships.count > 1
      errors.add(:base, "Personal accounts can only have one user")
    end
  end

  def can_invite_members
    errors.add(:base, "Personal accounts cannot invite members") if personal?
  end

  def default_personal_name?
    stored_name = read_attribute(:name).to_s
    return true if stored_name.blank?
    return true if owner&.email_address.present? && stored_name == "#{owner.email_address}'s Account"

    stored_name.end_with?("'s Account")
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

  def mark_memberships_for_skip_check
    memberships.each { |m| m.skip_owner_check = true }
  end

end
