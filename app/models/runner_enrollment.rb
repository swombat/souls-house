# One host runner's enrollment on one VM: a one-time token minted before the
# server is ordered, then the runner's pinned public key and heartbeats.
#
# Deliberately separate from procurement's state machine (#191). Procurement
# provisioned is not runner enrolled; enrolled is not healthy; healthy is not
# runtime-ready. Nothing here makes a placement ready or allows dispatch.
class RunnerEnrollment < ApplicationRecord

  TOKEN_TTL = 24.hours
  HEALTHY_WITHIN = 3.minutes
  PUBLIC_KEY_BYTES = 32

  class Refused < StandardError

    attr_reader :code, :status

    def initialize(code, status)
      @code = code
      @status = status
      super(code.to_s)
    end

  end

  belongs_to :agent_placement
  has_many :request_nonces, class_name: "RunnerRequestNonce", dependent: :delete_all

  validates :public_id, :token_digest, :expires_at, presence: true
  validates :expected_provider_server_id, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :public_key_is_raw_ed25519

  # Called by procurement inside the transaction that commits its create
  # intent. Returns [enrollment, plaintext token]. Only the digest is stored;
  # the plaintext belongs in that one create request's user_data and nowhere
  # else. There is no re-mint: a lost plaintext means operator review.
  def self.mint!(placement:, operation_id: nil, now: Time.current)
    token = SecureRandom.urlsafe_base64(32)
    enrollment = create!(
      agent_placement: placement,
      procurement_operation_id: operation_id,
      public_id: "rnr_#{SecureRandom.hex(10)}",
      token_digest: digest(token),
      expires_at: now + TOKEN_TTL
    )
    [ enrollment, token ]
  end

  def self.digest(token)
    OpenSSL::Digest::SHA256.hexdigest(token.to_s)
  end

  # Called by procurement once it has confirmed the provider server for this
  # operation. Until then, enrollment answers "pending" and burns nothing.
  def confirm_provider_server!(server_id)
    with_lock do
      if expected_provider_server_id.present? && expected_provider_server_id != server_id
        raise Refused.new(:provider_server_already_confirmed, 409)
      end
      update!(expected_provider_server_id: server_id)
    end
  end

  # Returns :pending, :enrolled or :already_enrolled; raises Refused.
  # The caller has already verified that the request was signed with
  # public_key, so the runner holds the matching private key.
  def enroll!(token:, public_key:, reported_server_id:, facts:, now: Time.current)
    with_lock do
      raise Refused.new(:revoked, 403) if revoked_at
      raise Refused.new(:invalid_token, 401) unless ActiveSupport::SecurityUtils.secure_compare(self.class.digest(token), token_digest)

      if enrolled_at
        return :already_enrolled if ActiveSupport::SecurityUtils.secure_compare(public_key.to_s, self.public_key.to_s)

        raise Refused.new(:key_mismatch, 409)
      end

      raise Refused.new(:expired, 410) if now >= expires_at
      return :pending if expected_provider_server_id.nil?
      raise Refused.new(:server_mismatch, 409) unless reported_server_id == expected_provider_server_id

      update!(public_key: public_key, enrolled_at: now, last_facts: facts)
      :enrolled
    end
  end

  def heartbeat!(reported_server_id:, facts:, now: Time.current)
    raise Refused.new(:revoked, 403) if revoked_at
    raise Refused.new(:not_enrolled, 409) unless enrolled_at
    raise Refused.new(:server_mismatch, 409) unless reported_server_id == expected_provider_server_id

    update!(last_heartbeat_at: now, last_facts: facts)
  end

  def enrolled? = enrolled_at.present?

  def healthy?(now: Time.current)
    enrolled? && revoked_at.nil? && last_heartbeat_at.present? && last_heartbeat_at > now - HEALTHY_WITHIN
  end

  def revoke!(now: Time.current)
    update!(revoked_at: now)
  end

  private

  def public_key_is_raw_ed25519
    return if public_key.nil?

    raw = Base64.strict_decode64(public_key)
    errors.add(:public_key, "must be a raw Ed25519 public key") unless raw.bytesize == PUBLIC_KEY_BYTES
  rescue ArgumentError
    errors.add(:public_key, "must be strict base64")
  end

end
