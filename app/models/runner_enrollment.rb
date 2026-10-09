# One host runner's enrollment on one VM: a one-time token minted before the
# server is ordered, then the runner's pinned public key and heartbeats.
#
# Deliberately separate from procurement's state machine (#191). Procurement
# provisioned is not runner enrolled; enrolled is not healthy; healthy is not
# runtime-ready. Nothing here makes a placement ready or allows dispatch.
class RunnerEnrollment < ApplicationRecord

  TOKEN_TTL = 24.hours
  # Nonces are kept past the whole accepted timestamp window, including
  # requests dated up to MAX_SKEW in the future.
  NONCE_RETENTION = (RunnerSignature::MAX_SKEW * 2 + 60).seconds
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
  has_many :commands, class_name: "RunnerCommand", dependent: :restrict_with_exception

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

  def authenticate_token!(token)
    return if ActiveSupport::SecurityUtils.secure_compare(self.class.digest(token), token_digest)

    raise Refused.new(:invalid_token, 401)
  end

  # Returns :pending, :enrolled or :already_enrolled; raises Refused.
  # A spent token answers "already enrolled" only for the same key, the same
  # confirmed server and inside the token's lifetime. After that, a runner
  # whose enrollment reply was lost recovers with a signed heartbeat.
  # The caller has already verified that the request was signed with
  # public_key, so the runner holds the matching private key.
  #
  # Every eligibility check runs under the row lock before anything is
  # written. The request's nonce is consumed in the same transaction as the
  # enrollment change, so a refusal (expired, revoked, wrong key or server)
  # rolls back and leaves the nonce table untouched.
  def enroll!(token:, public_key:, reported_server_id:, facts:, nonce:, now: Time.current)
    with_lock do
      raise Refused.new(:revoked, 403) if revoked_at
      authenticate_token!(token)
      raise Refused.new(:expired, 410) if now >= expires_at

      if enrolled_at
        raise Refused.new(:key_mismatch, 409) unless ActiveSupport::SecurityUtils.secure_compare(public_key.to_s, self.public_key.to_s)
        raise Refused.new(:server_mismatch, 409) unless reported_server_id == expected_provider_server_id

        consume_nonce!(nonce, now)
        return :already_enrolled
      end

      if expected_provider_server_id.nil?
        consume_nonce!(nonce, now)
        return :pending
      end
      raise Refused.new(:server_mismatch, 409) unless reported_server_id == expected_provider_server_id

      consume_nonce!(nonce, now)
      update!(public_key: public_key, enrolled_at: now, last_facts: facts)
      :enrolled
    end
  end

  # Same rule as enroll!: checks first, then nonce and heartbeat together.
  def heartbeat!(reported_server_id:, facts:, nonce:, now: Time.current)
    with_lock do
      raise Refused.new(:revoked, 403) if revoked_at
      raise Refused.new(:not_enrolled, 409) unless enrolled_at
      raise Refused.new(:server_mismatch, 409) unless reported_server_id == expected_provider_server_id

      consume_nonce!(nonce, now)
      update!(last_heartbeat_at: now, last_facts: facts)
    end
  end

  def enrolled? = enrolled_at.present?

  # The runner asks for its next command (#238). Same rule as heartbeat!:
  # every check under the row lock first, then the nonce, then the change.
  # Returns the command envelope or nil. A command issued under an older
  # placement generation is refused here and never handed out.
  def poll!(nonce:, now: Time.current)
    with_lock do
      placement = require_live!
      consume_nonce!(nonce, now)
      generation = placement.generation
      while (command = RunnerCommand.next_for(self, now:))
        if command.generation < generation
          command.refuse_locally!("stale generation", now:)
          next
        end
        if withdrawn_before_handoff?(command)
          command.refuse_locally!("turn withdrawn before delivery", now:)
          next
        end
        return command.deliver!(now:)
      end
      nil
    end
  end

  # The runner answers a command. Only a command this enrollment was given
  # can be answered, and only once; a repeated answer is accepted and ignored.
  # A command from an older placement generation can't be answered: a late
  # result must not settle anything for a placement that has moved on.
  def report_command_result!(public_id:, result:, nonce:, now: Time.current)
    with_lock do
      placement = require_live!
      command = commands.find_by(public_id: public_id.to_s) || raise(Refused.new(:unknown_command, 404))
      raise Refused.new(:not_delivered, 409) if command.state == "queued"
      raise Refused.new(:stale_generation, 409) if command.generation < placement.generation

      consume_nonce!(nonce, now)
      command.record_result!(result, now:)
      command
    end
  end

  # The runner asks for a resident image (#238 part 3). The house hands it
  # over only while this enrollment holds a delivered, unanswered
  # start_resident naming exactly that image ID. Same rule as the other
  # endpoints: every check under the lock before the nonce is consumed.
  IMAGE_ID = /\Asha256:[0-9a-f]{64}\z/

  def authorize_image!(image_id:, nonce:, now: Time.current)
    with_lock do
      placement = require_live!
      raise Refused.new(:bad_image, 404) unless IMAGE_ID.match?(image_id.to_s)

      wanted = commands.where(kind: "start_resident", state: "delivered")
        .where(generation: placement.generation).any? do |command|
          JSON.parse(command.payload_json.to_s)["image"] == image_id
        rescue JSON::ParserError
          false
        end
      raise Refused.new(:image_not_requested, 404) unless wanted

      consume_nonce!(nonce, now)
      image_id
    end
  end

  def healthy?(now: Time.current)
    enrolled? && revoked_at.nil? && last_heartbeat_at.present? && last_heartbeat_at > now - HEALTHY_WITHIN
  end

  def authorize_backup!(nonce:, now: Time.current)
    with_lock do
      placement = require_live!
      raise Refused.new(:placement_unavailable, 409) if placement.state == "failed"
      wanted = commands.where(kind: "backup_resident", state: "delivered", generation: placement.generation).exists?
      raise Refused.new(:backup_not_requested, 404) unless wanted
      consume_nonce!(nonce, now)
      placement.agent
    end
  end

  # The runner asks for its resident's first home (#246 slice 3). Same rule
  # as images: only while this enrollment holds a delivered, unanswered
  # seed_home of the current generation naming exactly that digest, and only
  # the archive stored on this enrollment's own placement. Returns the bytes.
  SEED_DIGEST = /\A[0-9a-f]{64}\z/

  def authorize_seed!(sha256:, nonce:, now: Time.current)
    with_lock do
      placement = require_live!
      raise Refused.new(:bad_seed, 404) unless SEED_DIGEST.match?(sha256.to_s)

      wanted = commands.where(kind: "seed_home", state: "delivered")
        .where(generation: placement.generation).any? do |command|
          JSON.parse(command.payload_json.to_s)["sha256"] == sha256
        rescue JSON::ParserError
          false
        end
      raise Refused.new(:seed_not_requested, 404) unless wanted

      archive = AgentPlacement.uncached { AgentPlacement.where(id: placement.id).pick(:seed_sha256, :seed_archive) }
      raise Refused.new(:seed_not_requested, 404) unless archive && archive[0] == sha256 && archive[1].present?

      consume_nonce!(nonce, now)
      archive[1]
    end
  end

  def revoke!(now: Time.current)
    update!(revoked_at: now)
  end

  private

  # The no-new-starts boundary, carried across the queue: a submission that
  # has never been handed out is checked again here, at the last moment it
  # can still be stopped. A withdrawn turn's submit is refused locally; the
  # poll job then finds the resident never saw it and sends a cancellation
  # instead. A submit that was already delivered keeps its uncertainty: the
  # runner may have it, so it is never refused here.
  def withdrawn_before_handoff?(command)
    return false unless command.kind == "submit_turn" && command.state == "queued"

    turn = command.resident_turn
    return true unless turn

    turn.withdraw_unless_deliverable!
    turn.reload
    turn.cancel_requested_at? || turn.finished_at?
  end

  # Returns the placement, read fresh under the enrollment lock. A retired
  # placement gets no commands and settles no results, whatever the state of
  # its enrollment.
  def require_live!
    raise Refused.new(:revoked, 403) if revoked_at
    raise Refused.new(:not_enrolled, 409) unless enrolled_at

    placement = AgentPlacement.uncached { AgentPlacement.find(agent_placement_id) }
    raise Refused.new(:placement_retired, 410) if placement.state == "retired"

    placement
  end

  # Inside the caller's transaction. A duplicate nonce violates the unique
  # index; the raise rolls the whole transaction back.
  def consume_nonce!(nonce, now)
    request_nonces.where(created_at: ...(now - NONCE_RETENTION)).delete_all
    request_nonces.create!(nonce:, created_at: now)
  rescue ActiveRecord::RecordNotUnique
    raise RunnerSignature::Invalid.new(:replayed_nonce)
  end

  def public_key_is_raw_ed25519
    return if public_key.nil?

    raw = Base64.strict_decode64(public_key)
    errors.add(:public_key, "must be a raw Ed25519 public key") unless raw.bytesize == PUBLIC_KEY_BYTES
  rescue ArgumentError
    errors.add(:public_key, "must be strict base64")
  end

end
