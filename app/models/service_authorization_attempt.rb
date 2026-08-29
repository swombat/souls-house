class ServiceAuthorizationAttempt < ApplicationRecord

  belongs_to :account
  belongs_to :user
  belongs_to :service_connection, optional: true

  encrypts :pkce_verifier

  validates :provider, :management_scope, :state_digest, :expires_at, presence: true
  validates :state_digest, uniqueness: true
  validate :provider_contract

  scope :available, -> { where(consumed_at: nil).where("expires_at > ?", Time.current) }

  def self.begin!(account:, user:, provider:, management_scope:, access_profile: nil,
                  authority_selection: nil, service_connection: nil, return_path:)
    definition = Services::Definition.fetch(provider)
    if definition.structured_authority? && authority_selection.present?
      normalized_authority = definition.normalize_authority_selection(authority_selection)
      profile = nil
      scopes = definition.scopes_for_authority(normalized_authority)
    else
      profile = access_profile.presence || definition.default_access_profile
      normalized_authority = {}
      scopes = definition.scopes_for(profile)
    end
    raw_state = SecureRandom.urlsafe_base64(48)

    attempt = create!(
      account: account,
      user: user,
      provider: definition.key,
      management_scope: management_scope,
      access_profile: profile,
      authority_selection: normalized_authority,
      requested_scopes: scopes,
      service_connection: service_connection,
      state_digest: digest(raw_state),
      pkce_verifier: SecureRandom.urlsafe_base64(64),
      return_path: return_path,
      expires_at: 15.minutes.from_now
    )
    [ attempt, raw_state ]
  end

  def self.resolve!(raw_state)
    available.lock.find_by!(state_digest: digest(raw_state))
  end

  def consume!
    with_lock do
      raise ActiveRecord::RecordNotFound if consumed_at? || expires_at <= Time.current
      update!(consumed_at: Time.current)
    end
  end

  def definition
    Services::Definition.fetch(provider)
  end

  def self.digest(value)
    Digest::SHA256.hexdigest(value.to_s)
  end

  private

  def provider_contract
    definition = Services::Definition.fetch(provider)
    errors.add(:management_scope, "is not supported") unless definition.supports_management_scope?(management_scope)
    if authority_selection.present?
      definition.normalize_authority_selection(authority_selection)
    elsif !definition.access_profiles.key?(access_profile.to_s)
      errors.add(:access_profile, "is not supported")
    end
    if service_connection && (service_connection.account_id != account_id || service_connection.provider != provider)
      errors.add(:service_connection, "does not match this authorization")
    end
  rescue ArgumentError => e
    errors.add(:authority_selection, e.message)
  rescue Services::Definition::UnknownProvider => e
    errors.add(:provider, e.message)
  end

end
