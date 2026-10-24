class CompanionEnrollmentGrant < ApplicationRecord

  include ObfuscatesId

  TOKEN_PREFIX = "shce_".freeze
  MAX_LIFETIME = 24.hours
  ENROLLMENT_RECOVERY_WINDOW = 10.minutes
  REQUEST_ID = /\A[A-Za-z0-9_.:-]{1,128}\z/
  PUBLIC_ID = /\A[A-Za-z]{6,128}\z/

  class InvalidPolicy < StandardError; end

  belongs_to :account
  belongs_to :minting_agent, class_name: "Agent"
  belongs_to :created_by_user, class_name: "User"
  has_one :companion_device

  encrypts :enrollment_response

  attr_readonly :account_id, :minting_agent_id, :created_by_user_id, :device_request_id, :name, :policy, :expires_at

  validates :name, presence: true, length: { maximum: 100 }
  validates :device_request_id, format: { with: REQUEST_ID }
  validates :expires_at, presence: true
  validate :valid_authority_and_policy, on: :create

  # Validate the whole shape rather than silently dropping unknown permissions.
  # IDs are canonical public agent IDs, resolved only through the home account.
  def self.normalize_policy(account, value)
    invalid = -> { raise InvalidPolicy, "Invalid companion policy" }
    invalid.call unless value.is_a?(Hash) && value.keys == [ "residents" ]
    residents = value["residents"]
    invalid.call unless residents.is_a?(Array) && residents.size.between?(1, 128)
    ids = []
    volume_count = 0
    normalized = residents.map do |resident|
      invalid.call unless resident.is_a?(Hash) && resident.keys.sort == %w[execute id volumes]
      id = resident["id"]
      invalid.call unless id.is_a?(String) && PUBLIC_ID.match?(id)
      agent = account.agents.find_by(id: Agent.decode_id(id))
      invalid.call unless agent && agent.to_param == id && !ids.include?(id)
      ids << id
      invalid.call unless [ true, false ].include?(resident["execute"])
      volumes = resident["volumes"]
      invalid.call unless volumes.is_a?(Array) && volumes.size <= 128
      volume_count += volumes.size
      invalid.call if volume_count > 128
      keys = []
      normalized_volumes = volumes.map do |volume|
        invalid.call unless volume.is_a?(Hash) && volume.keys.sort == %w[access volume]
        key = volume["volume"]
        invalid.call unless key.is_a?(String) && key.bytesize.between?(1, 128) &&
          !key.match?(/[[:cntrl:]]/) && !keys.include?(key) && %w[read write].include?(volume["access"])
        keys << key
        { "volume" => key, "access" => volume["access"] }
      end
      { "id" => id, "volumes" => normalized_volumes, "execute" => resident["execute"] }
    end
    { "residents" => normalized }
  rescue Hashids::InputError
    raise InvalidPolicy, "Invalid companion policy"
  end

  def authority_warnings
    residents = policy.fetch("residents")
    warnings = []
    if residents.any? { |resident| resident.fetch("volumes").any? { |volume| volume["access"] == "write" } }
      warnings << "Write access to a volume containing the service user's home must be treated as deferred " \
        "arbitrary code execution as that user (for example, by modifying .bashrc or other startup files), " \
        "even without an execute grant."
    end
    if residents.any? { |resident| resident["execute"] }
      warnings << "Execute grants allow arbitrary code execution with the service user's OS authority. " \
        "Executed programs can rewrite state.json, including the local ceiling. The companion is not a " \
        "sandbox, and the local ceiling is not an enforceable limit against an execute-granted actor."
    end
    warnings
  end

  def issue_token!(agent)
    with_lock do
      return unless agent && agent.id == minting_agent_id && agent.account_id == account_id &&
        !account.reload.disabled? && expires_at > Time.current && consumed_at.nil? && token_digest.nil?

      value = "#{TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
      update!(token_digest: Digest::SHA256.hexdigest(value))
      value
    end
  end

  # Returns [device, credential, response]. After a lost response, only the
  # identical enrollment token AND request ID may recover the encrypted response
  # for ten minutes. Consumption, device creation and response cache commit as one.
  def self.enroll!(value, request_id)
    return unless value.is_a?(String) && value.match?(/\Ashce_[A-Za-z0-9_-]{43}\z/) &&
      request_id.is_a?(String) && REQUEST_ID.match?(request_id)

    grant = find_by(token_digest: Digest::SHA256.hexdigest(value))
    return unless grant

    grant.with_lock do
      return unless grant.device_request_id == request_id && !grant.account.reload.disabled?
      if grant.consumed_at
        return unless grant.enrollment_retry_until && grant.enrollment_retry_until > Time.current

        device = grant.companion_device
        return unless device&.active?

        response = JSON.parse(grant.enrollment_response)
        return [ device, response.fetch("device_credential"), response ]
      end
      return unless grant.expires_at > Time.current

      policy = normalize_policy(grant.account, grant.policy)
      credential = CompanionDevice.generate_credential
      device = CompanionDevice.create!(
        account: grant.account, companion_enrollment_grant: grant, name: grant.name,
        policy: policy, credential_digest: CompanionDevice.digest(credential), grant_revision: 1
      )
      response = { "device_id" => device.obfuscated_id, "device_credential" => credential,
        "policy" => device.policy, "revision" => device.grant_revision }
      grant.update!(consumed_at: Time.current, enrollment_retry_until: ENROLLMENT_RECOVERY_WINDOW.from_now,
        enrollment_response: JSON.generate(response))
      AuditLog.create!(account: grant.account, auditable: device, action: "companion.device.enrolled",
        data: { enrollment_grant_id: grant.obfuscated_id, minting_agent_id: grant.minting_agent.obfuscated_id })
      [ device, credential, response ]
    end
  rescue InvalidPolicy
    nil
  end

  private

  def valid_authority_and_policy
    errors.add(:minting_agent, "must belong to this account") unless minting_agent&.account_id == account_id
    errors.add(:expires_at, "must be in the next 24 hours") unless expires_at && expires_at > Time.current && expires_at <= MAX_LIFETIME.from_now
    self.policy = self.class.normalize_policy(account, policy) if account
  rescue InvalidPolicy => error
    errors.add(:policy, error.message)
  end

end
