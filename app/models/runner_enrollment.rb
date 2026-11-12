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
  # Birth fetches per enrollment (#779). The fetch script retries every 30 s
  # for at most 40 minutes (~80 attempts); past this the token's one read is
  # refused, durably, whatever the cache does.
  MAX_BIRTH_FETCHES = 120

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
  validates :procurement_kind, inclusion: { in: %w[hetzner_cloud boat] }
  validates :expected_provider_sandbox_id, format: { with: BoatClient::SANDBOX_ID }, allow_nil: true
  validate :public_key_is_raw_ed25519

  # Called by procurement inside the transaction that commits its create
  # intent. Returns [enrollment, plaintext token]. Only the digest is stored;
  # the plaintext belongs in that one create request's user_data and nowhere
  # else. There is no re-mint: a lost plaintext means operator review.
  def self.mint!(placement:, operation_id: nil, boat_operation_id: nil, now: Time.current)
    raise ArgumentError, "one purchase, Hetzner or Boat" if operation_id && boat_operation_id

    token = SecureRandom.urlsafe_base64(32)
    enrollment = create!(
      agent_placement: placement,
      procurement_operation_id: operation_id,
      boat_procurement_operation_id: boat_operation_id,
      procurement_kind: boat_operation_id ? "boat" : "hetzner_cloud",
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
      raise Refused.new(:wrong_provider, 409) unless procurement_kind == "hetzner_cloud"
      if expected_provider_server_id.present? && expected_provider_server_id != server_id
        raise Refused.new(:provider_server_already_confirmed, 409)
      end
      update!(expected_provider_server_id: server_id)
    end
  end

  # The Boat twin of confirm_provider_server!: a Boat runner reports the
  # sandbox id Boat sets in its reserved BOAT_ID variable.
  def confirm_provider_sandbox!(sandbox_id)
    with_lock do
      raise Refused.new(:wrong_provider, 409) unless procurement_kind == "boat"
      if expected_provider_sandbox_id.present? && expected_provider_sandbox_id != sandbox_id
        raise Refused.new(:provider_server_already_confirmed, 409)
      end
      update!(expected_provider_sandbox_id: sandbox_id)
    end
  end

  # What this runner must report it is running on: a Hetzner server id or a
  # Boat sandbox id, never one standing in for the other.
  def expected_machine_id
    procurement_kind == "boat" ? expected_provider_sandbox_id : expected_provider_server_id
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
        raise Refused.new(:server_mismatch, 409) unless reported_server_id == expected_machine_id

        consume_nonce!(nonce, now)
        return :already_enrolled
      end

      if expected_machine_id.nil?
        consume_nonce!(nonce, now)
        return :pending
      end
      raise Refused.new(:server_mismatch, 409) unless reported_server_id == expected_machine_id

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
      raise Refused.new(:server_mismatch, 409) unless reported_server_id == expected_machine_id

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
  IMAGE_FETCH_KINDS = %w[start_resident check_runtime_trust].freeze

  def authorize_image!(image_id:, nonce:, now: Time.current)
    with_lock do
      placement = require_live!
      raise Refused.new(:bad_image, 404) unless IMAGE_ID.match?(image_id.to_s)

      # A GitHub import's runtime trust check (check_runtime_trust) runs in the
      # resident's image before any start_resident exists, so it may fetch the
      # image it was sent too; without this every VM import failed at 404.
      wanted = commands.where(kind: IMAGE_FETCH_KINDS, state: "delivered")
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

  # A delivered backup_resident authorises the whole restic protocol; a
  # delivered restore_carry (#426 slice 3C) authorises reads only, so a
  # restore can never write, lock or delete in the repository. A delivered
  # rollback_snapshot (#426 3C rollback) writes one snapshot of a stopped
  # resident into a repository that already exists: everything but init.
  BACKUP_READS = %i[read head list].freeze

  def authorize_backup!(nonce:, operation:, now: Time.current)
    with_lock do
      placement = require_live!
      raise Refused.new(:placement_unavailable, 409) if placement.state == "failed"
      kinds = if BACKUP_READS.include?(operation)
        %w[backup_resident restore_carry rollback_snapshot]
      elsif operation == :init
        %w[backup_resident]
      else
        %w[backup_resident rollback_snapshot]
      end
      wanted = commands.where(kind: kinds, state: "delivered", generation: placement.generation).exists?
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
      bytes = archive[1] if archive && archive[0] == sha256
      # An archive import's or a migration's role homes, and a GitHub
      # import's reviewed identity, are staged on its resident
      # (AgentImportStage), each named by its own digest.
      if bytes.blank? && %w[archive_import github_import migration].include?(placement.kind)
        bytes = AgentImportStage.uncached { AgentImportStage.where(agent_id: placement.agent_id, sha256:).pick(:archive) }
      end
      raise Refused.new(:seed_not_requested, 404) if bytes.blank?

      consume_nonce!(nonce, now)
      bytes
    end
  end

  # One of this release's runner packages (#593; birth or full, #426 3C),
  # served only to this enrollment's runner while a delivered update_runner
  # of the current generation names exactly this digest.
  def authorize_runner_bundle!(sha256:, nonce:, now: Time.current)
    with_lock do
      placement = require_live!
      bundle = RunnerBundle.find(sha256)
      raise Refused.new(:runner_bundle_not_requested, 404) unless bundle

      wanted = commands.where(kind: "update_runner", state: "delivered", generation: placement.generation).any? do |command|
        JSON.parse(command.payload_json.to_s)["sha256"] == sha256
      rescue JSON::ParserError
        false
      end
      raise Refused.new(:runner_bundle_not_requested, 404) unless wanted

      consume_nonce!(nonce, now)
      bundle.bytes
    end
  end

  # The bytes this enrollment's user_data pins (#779), for the VM's birth
  # fetch. The token authorises the read and is not spent: enroll! spends it.
  # Only before enrollment, inside the token's lifetime, for exactly the
  # pinned digest, and never once the placement is retired.
  def authorize_birth_bundle!(token:, sha256:, now: Time.current)
    raise Refused.new(:revoked, 403) if revoked_at
    authenticate_token!(token)
    raise Refused.new(:expired, 410) if now >= expires_at
    raise Refused.new(:already_enrolled, 409) if enrolled_at

    placement = AgentPlacement.uncached { AgentPlacement.find(agent_placement_id) }
    raise Refused.new(:placement_retired, 410) if placement.state == "retired"
    unless birth_bundle_sha256.present? && ActiveSupport::SecurityUtils.secure_compare(sha256.to_s, birth_bundle_sha256)
      raise Refused.new(:birth_bundle_not_pinned, 404)
    end

    bundle = RunnerBirthBundle.find_by(sha256: birth_bundle_sha256) || raise(Refused.new(:birth_bundle_not_pinned, 404))
    counted = self.class.where(id:).where(birth_bundle_fetches: ...MAX_BIRTH_FETCHES)
      .update_all("birth_bundle_fetches = birth_bundle_fetches + 1")
    raise Refused.new(:too_many_birth_fetches, 429) if counted.zero?

    bundle.bytes
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
