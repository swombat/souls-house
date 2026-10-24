class CompanionDevice < ApplicationRecord

  include ObfuscatesId

  CREDENTIAL_PREFIX = "shcd_".freeze
  RECOVERY_WINDOW = 60.seconds

  class InvalidCredential < StandardError; end
  class Paused < StandardError; end
  class RetryConflict < StandardError; end

  belongs_to :account
  belongs_to :companion_enrollment_grant
  has_many :companion_cable_tickets, dependent: :delete_all

  encrypts :session_response
  attr_readonly :account_id, :companion_enrollment_grant_id, :name, :policy

  validates :name, presence: true, length: { maximum: 100 }
  validates :credential_digest, presence: true, uniqueness: true
  validates :grant_revision, numericality: { only_integer: true, greater_than: 0 }
  validate :grant_account_matches, on: :create

  def self.generate_credential
    "#{CREDENTIAL_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
  end

  def self.digest(value)
    Digest::SHA256.hexdigest(value)
  end

  def self.credential?(value)
    value.is_a?(String) && value.match?(/\Ashcd_[A-Za-z0-9_-]{43}\z/)
  end

  # Previous credentials are NOT general device authority. Only create_session!
  # accepts them, only to recover the exact previous response.
  def self.authenticate(value)
    return unless credential?(value)

    device = find_by(credential_digest: digest(value), revoked_at: nil)
    device if device&.active?
  end

  def active?
    revoked_at.nil? && !paused? && !account.reload.disabled?
  end

  def revoke!(actor: nil)
    with_lock do
      return if revoked_at

      update!(revoked_at: Time.current, connection_epoch: nil, previous_credential_digest: nil,
        session_response: nil, session_request_id: nil, session_retry_until: nil)
      AuditLog.create!(user: actor, account: account, auditable: self, action: "companion.device.revoked",
        data: { device_id: obfuscated_id })
    end
  end

  # Serialize rotations. During recovery, even a new current credential cannot
  # start another rotation with a different request ID: that would silently
  # destroy the outstanding retry's recoverability. Conflicts never revoke.
  def self.create_session!(value, request_id)
    raise InvalidCredential unless credential?(value)
    raise ArgumentError, "request_id must be 1-128 safe characters" unless request_id.is_a?(String) &&
      CompanionEnrollmentGrant::REQUEST_ID.match?(request_id)

    supplied_digest = digest(value)
    device = where(credential_digest: supplied_digest).or(where(previous_credential_digest: supplied_digest)).first
    raise InvalidCredential unless device

    response = device.with_lock do
      raise InvalidCredential unless device.revoked_at.nil? && !device.account.reload.disabled?

      current = ActiveSupport::SecurityUtils.secure_compare(device.credential_digest, supplied_digest)
      previous = device.previous_credential_digest == supplied_digest
      raise InvalidCredential unless current || previous

      recovering = device.session_retry_until && device.session_retry_until > Time.current
      if previous && !recovering
        AuditLog.create!(account: device.account, auditable: device, action: "companion.device.stale_credential",
          data: { device_id: device.obfuscated_id })
        # Refuse outside this transaction, or raising would roll back the audit.
        next nil
      end
      raise InvalidCredential unless current || device.session_request_id == request_id
      if recovering
        if device.session_request_id == request_id &&
            (current || previous)
          return JSON.parse(device.session_response)
        end
        raise Paused if device.paused?
        raise RetryConflict if current
      end
      raise InvalidCredential unless current
      raise Paused if device.paused?
      # Don't reuse a completed request ID for a fresh rotation.
      raise RetryConflict if device.session_request_id == request_id

      next_credential = generate_credential
      ticket_value, ticket = CompanionCableTicket.issue!(device)
      response = {
        "device_id" => device.to_param, "device_credential" => next_credential,
        "cable_ticket" => ticket_value, "policy" => device.policy,
        "revision" => device.grant_revision, "expires_at" => ticket.expires_at.iso8601(3)
      }
      device.update!(
        previous_credential_digest: device.credential_digest,
        credential_digest: digest(next_credential), session_request_id: request_id,
        session_retry_until: RECOVERY_WINDOW.from_now, session_response: JSON.generate(response)
      )
      response
    end
    raise InvalidCredential unless response

    response
  end

  private

  def grant_account_matches
    unless companion_enrollment_grant&.account_id == account_id
      errors.add(:companion_enrollment_grant, "must belong to this account")
    end
  end

end
