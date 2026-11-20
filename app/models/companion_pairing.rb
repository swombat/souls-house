# A computer asking to be added to an account, by code (YMamQY).
#
# The computer opens a pairing with no login: its name, the disks it offers
# and the most each may be granted. It gets back a short code to show its
# person, and a poll secret it keeps. A confirmed member of an account types
# the code on the Computers page, picks residents and access (never above the
# offer) and approves. Approval creates an ordinary CompanionEnrollmentGrant
# and issues its one-use token server-side; the computer collects the token
# with its poll secret and enrolls through the existing /enroll, so the device
# credential and the policy checks are the ones every computer already uses.
#
# Nothing here grants anything until a person with authority on an account
# approves. The code is a rendezvous, not a credential: it can't be redeemed
# by the computer, only approved by a member who is signed in.
class CompanionPairing < ApplicationRecord

  include ObfuscatesId

  LIFETIME = 15.minutes
  # How long an approved pairing's token stays collectable (and the grant valid).
  APPROVAL_WINDOW = 15.minutes
  CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789".freeze
  CODE_LENGTH = 8
  SECRET_PREFIX = "shcp_".freeze
  SECRET = /\Ashcp_[A-Za-z0-9_-]{43}\z/
  MAX_VOLUMES = 16
  ACCESS = %w[read write].freeze
  KINDS = %w[computer pocket].freeze
  # What a pocket device can offer. Each starts switched off on the device's
  # card; offering it only means the hardware has it.
  CAPABILITIES = %w[mic camera].freeze

  class Invalid < StandardError; end

  belongs_to :account, optional: true
  belongs_to :approved_by_user, class_name: "User", optional: true
  belongs_to :companion_enrollment_grant, optional: true

  encrypts :enrollment_token

  validates :name, presence: true, length: { maximum: 100 }
  validates :device_request_id, format: { with: CompanionEnrollmentGrant::REQUEST_ID }
  validates :kind, inclusion: { in: KINDS }

  scope :pending, -> { where(approved_at: nil).where("expires_at > ?", Time.current) }

  def pocket? = kind == "pocket"

  # Returns [pairing, code, poll_secret]. Raises Invalid on any malformed field.
  # A computer offers volumes; a pocket offers capabilities and no volumes.
  def self.open!(name:, device_request_id:, volumes:, kind: nil, capabilities: nil)
    raise Invalid, "Invalid name" unless name.is_a?(String) && name.strip.bytesize.between?(1, 100) &&
      !name.match?(/[[:cntrl:]]/)
    raise Invalid, "Invalid device_request_id" unless device_request_id.is_a?(String) &&
      CompanionEnrollmentGrant::REQUEST_ID.match?(device_request_id)
    kind = kind.nil? ? "computer" : kind
    raise Invalid, "Invalid kind" unless KINDS.include?(kind)

    if kind == "pocket"
      raise Invalid, "A pocket device offers no volumes" unless volumes.nil?
      offered = nil
      offered_capabilities = normalize_capabilities(capabilities)
    else
      raise Invalid, "A computer offers no capabilities" unless capabilities.nil?
      offered = normalize_volumes(volumes)
      offered_capabilities = nil
    end
    secret = "#{SECRET_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
    5.times do
      code = Array.new(CODE_LENGTH) { CODE_ALPHABET[SecureRandom.random_number(CODE_ALPHABET.size)] }.join
      pairing = create!(name: name.strip, device_request_id: device_request_id, offered_volumes: offered,
        kind: kind, offered_capabilities: offered_capabilities,
        code_digest: digest(code), poll_secret_digest: Digest::SHA256.hexdigest(secret),
        expires_at: LIFETIME.from_now)
      return [ pairing, display_code(code), secret ]
    rescue ActiveRecord::RecordNotUnique
      next
    end
    raise Invalid, "Couldn't make a code"
  end

  def self.normalize_capabilities(value)
    unless value.is_a?(Array) && value.size.between?(1, CAPABILITIES.size) &&
        value.all? { |c| CAPABILITIES.include?(c) } && value.uniq.size == value.size
      raise Invalid, "Invalid capabilities"
    end

    CAPABILITIES & value
  end

  # Expired rendezvous data goes. A pending pairing goes an hour after its
  # code expired; an approved one once its grant can no longer be collected
  # (expired or used). The grant, the device and the approval audit stay.
  def self.sweep!(now = Time.current)
    where(approved_at: nil).where(expires_at: ...(now - 1.hour)).delete_all
    where.not(approved_at: nil).where(companion_enrollment_grant_id: CompanionEnrollmentGrant
      .where(expires_at: ...now).or(CompanionEnrollmentGrant.where.not(consumed_at: nil)).select(:id)).delete_all
  end

  def self.normalize_volumes(value)
    invalid = -> { raise Invalid, "Invalid volumes" }
    invalid.call unless value.is_a?(Array) && value.size.between?(1, MAX_VOLUMES)
    keys = []
    value.map do |volume|
      volume = volume.to_h if volume.is_a?(ActiveSupport::HashWithIndifferentAccess)
      invalid.call unless volume.is_a?(Hash) && volume.keys.map(&:to_s).sort == %w[access label volume]
      key, label, access = volume.values_at("volume", "label", "access")
      invalid.call unless key.is_a?(String) && key.bytesize.between?(1, 128) && !key.match?(/[[:cntrl:]]/) &&
        !keys.include?(key)
      invalid.call unless label.is_a?(String) && label.bytesize.between?(1, 100) && !label.match?(/[[:cntrl:]]/)
      invalid.call unless ACCESS.include?(access)
      keys << key
      { "volume" => key, "label" => label, "access" => access }
    end
  end

  # Case, spaces and dashes don't matter when typing a code.
  def self.normalize_code(input)
    return unless input.is_a?(String) && input.bytesize <= 64

    code = input.upcase.delete("- \t")
    code if code.size == CODE_LENGTH && code.each_char.all? { |c| CODE_ALPHABET.include?(c) }
  end

  def self.digest(code)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "companion-pairing:#{code}")
  end

  def self.display_code(code)
    "#{code[0, 4]}-#{code[4, 4]}"
  end

  def self.find_pending_by_code(input)
    code = normalize_code(input)
    code && pending.find_by(code_digest: digest(code))
  end

  # Approve for `account`: each agent gets each chosen volume at its chosen
  # access, never above what the computer offered. `accesses` maps volume key
  # => "read" | "write" | "off". Returns the grant.
  def approve!(account:, user:, agents:, accesses:)
    return approve_pocket!(account: account, user: user, agents: agents) if pocket?

    with_lock do
      raise Invalid, "This code has expired or was already used" unless approved_at.nil? && expires_at > Time.current
      raise Invalid, "Choose at least one resident" if agents.empty?
      raise Invalid, "That resident isn't in this account" unless agents.all? { |a| a.account_id == account.id }
      raise Invalid, "This account is disabled" if account.disabled?

      volumes = offered_volumes.filter_map do |offered|
        access = accesses.fetch(offered["volume"], "off").to_s
        raise Invalid, "Unknown access" unless CompanionDevice::ACCESS_RANK.key?(access)
        next if access == "off"
        if CompanionDevice::ACCESS_RANK.fetch(access) > CompanionDevice::ACCESS_RANK.fetch(offered["access"])
          raise Invalid, "#{name} doesn't offer that"
        end

        { "volume" => offered["volume"], "access" => access }
      end
      raise Invalid, "Choose at least one disk" if volumes.empty?

      policy = { "residents" => agents.uniq.map { |agent| { "id" => agent.to_param, "volumes" => volumes, "execute" => false } } }
      grant = CompanionEnrollmentGrant.create!(account: account, minting_agent: agents.first, created_by_user: user,
        name: name, device_request_id: device_request_id, policy: policy, expires_at: APPROVAL_WINDOW.from_now)
      token = grant.issue_token!(agents.first)
      raise Invalid, "Couldn't approve" unless token

      update!(account: account, approved_by_user: user, companion_enrollment_grant: grant,
        enrollment_token: token, approved_at: Time.current)
      AuditLog.create!(account: account, user: user, auditable: grant, action: "companion.pairing.approved",
        data: { pairing_id: obfuscated_id, device_request_id: device_request_id,
          resident_ids: agents.map(&:to_param), volumes: volumes })
      grant
    end
  end

  # A pocket serves exactly one resident in a conversation made for it here,
  # which the approval page names before the person approves (Mira, JpznZZ).
  # The person approving owns it: only they can turn its microphone or camera
  # on, and both start off. The grant fixes kind and conversation, and
  # enrollment copies them; nothing the device sends can change either.
  def approve_pocket!(account:, user:, agents:)
    with_lock do
      raise Invalid, "This code has expired or was already used" unless approved_at.nil? && expires_at > Time.current
      raise Invalid, "Choose one resident" unless agents.size == 1
      agent = agents.first
      raise Invalid, "That resident isn't in this account" unless agent.account_id == account.id
      raise Invalid, "This account is disabled" if account.disabled?

      chat = account.chats.create_with_message!({ title: name, manual_responses: true, model_id: agent.model_id },
        user: user, agent_ids: [ agent.id ])
      policy = { "residents" => [ { "id" => agent.to_param, "volumes" => [], "execute" => false } ] }
      grant = CompanionEnrollmentGrant.create!(account: account, minting_agent: agent, created_by_user: user,
        name: name, device_request_id: device_request_id, policy: policy, expires_at: APPROVAL_WINDOW.from_now,
        kind: "pocket", chat: chat, offered_capabilities: offered_capabilities)
      token = grant.issue_token!(agent)
      raise Invalid, "Couldn't approve" unless token

      update!(account: account, approved_by_user: user, companion_enrollment_grant: grant,
        enrollment_token: token, approved_at: Time.current)
      AuditLog.create!(account: account, user: user, auditable: grant, action: "companion.pairing.approved",
        data: { pairing_id: obfuscated_id, device_request_id: device_request_id, kind: "pocket",
          resident_ids: [ agent.to_param ], chat_id: chat.to_param, capabilities: offered_capabilities })
      grant
    end
  end

  # What the computer sees when it polls: [:pending], [:approved, payload] or
  # [:expired]. Nil when the secret doesn't match.
  def self.claim(id, secret)
    return unless id.is_a?(String) && id.match?(/\A[A-Za-z]{6,64}\z/) && secret.is_a?(String) && SECRET.match?(secret)

    pairing = find_by(id: decode_id(id))
    return unless pairing && pairing.to_param == id &&
      ActiveSupport::SecurityUtils.secure_compare(pairing.poll_secret_digest, Digest::SHA256.hexdigest(secret))

    pairing.claim_state
  rescue Hashids::InputError
    nil
  end

  def claim_state
    if approved_at
      grant = companion_enrollment_grant
      if grant && grant.consumed_at.nil? && grant.expires_at > Time.current && enrollment_token.present?
        return [ :approved, { "enrollment_token" => enrollment_token, "device_request_id" => device_request_id,
          "resident_ids" => grant.policy.fetch("residents").map { |r| r["id"] } } ]
      end
      update_column(:enrollment_token, nil) if enrollment_token.present?
      return [ :expired ]
    end
    expires_at > Time.current ? [ :pending ] : [ :expired ]
  end

end
