# Creates, reconciles and cleans up one Boat sandbox per placement (slice 2,
# ePokyY): the Boat twin of CloudProcurement, under the same rules.
#
# * intent (size, enrollment authority) is committed before HTTP
# * there is exactly one create POST per operation, ever; ambiguity is
#   reconciled against Boat by label, never retried
# * an empty discovery is not proof of absence: a submitted operation leaves
#   the unresolved set only through a validated refusal or verified deletion
# * provisioned does not make the placement ready or dispatchable; nothing
#   dispatches to a boat placement yet
#
# Boat-specific: "verified" means the sandbox carries this operation's labels,
# is awake, and reports its setupScript as done. A failed setup goes to an
# operator, because the runner can never enroll from a sandbox whose
# bootstrap did not finish.
#
# Only an installation admin plans a Boat purchase in this slice. There is no
# birth, move or placement policy here yet.
class BoatProcurement

  class NotAuthorized < StandardError; end
  class NotAllowed < StandardError; end

  # No TTL setting: BoatClient always creates with Boat's auto-stop off,
  # because a lifetime would stop a resident in the middle of work.
  Config = Data.define(:rails_url, :runner_commands, :sandbox_size) do
    def initialize(rails_url:, runner_commands: false, sandbox_size: "small")
      super(rails_url:, runner_commands: runner_commands == true, sandbox_size: sandbox_size.presence || "small")
    end

    def self.from_credentials
      settings = Rails.application.credentials.boat || {}
      new(
        rails_url: ENV["SOULSHOUSE_DOMAIN"].presence&.then { |domain| "https://#{domain}" },
        runner_commands: settings[:runner_commands] == true,
        sandbox_size: settings[:sandbox_size].to_s
      )
    end
  end

  # Same deadline as CloudProcurement: a stalled claim never sends its POST.
  SUBMIT_DEADLINE = CloudProcurement::SUBMIT_DEADLINE
  # 4xx codes Boat's create reference documents as rejecting the request
  # before anything is made, plus api_key_action_forbidden (seen live in the
  # slice 1 proof). Anything else, including an unrecognised 4xx, stays
  # unknown. idempotency_in_progress and idempotency_key_reused are not
  # refusals: both mean a request under this key may already have made one.
  # Capacity answers arrive as BoatClient::CapacityUnavailable.
  REFUSAL_CODES = %w[
    invalid_env invalid_files invalid_hosted_ports invalid_setup_script environment_forbidden
    unknown_environment machine_class_plan_required unauthorized api_key_action_forbidden
  ].freeze
  SETUP_DONE = "done".freeze
  SETUP_FAILED = "failed".freeze

  def self.from_credentials
    new(client: BoatClient.from_credentials, config: Config.from_credentials)
  end

  def initialize(client:, config:, minter: RunnerEnrollment, renderer: BoatSetupScript, clock: -> { Time.current })
    @client = client
    @config = config
    @minter = minter
    @renderer = renderer
    @clock = clock
  end

  # Fixes the size for one purchase. Sends nothing.
  def plan!(placement:, requested_by:, approval_reference:)
    require_admin!(requested_by)
    raise NotAllowed, "the house domain must be configured" if @config.rails_url.blank?
    unless BoatProcurementOperation::SANDBOX_SIZES.include?(@config.sandbox_size)
      raise NotAllowed, "sandbox size #{@config.sandbox_size} is not allowed"
    end

    BoatProcurementOperation.transaction do
      placement.lock!
      unless placement.backend == "boat" && placement.state == "pending" && placement.provider_sandbox_id.nil?
        raise NotAllowed, "placement is not an unprovisioned Boat placement"
      end
      raise NotAllowed, "placement has cleanup requested" if placement.cleanup_requested?
      if BoatProcurementOperation.unresolved.exists?(agent_placement_id: placement.id)
        raise NotAllowed, "placement already has an unresolved purchase"
      end

      public_id = "bpo-#{SecureRandom.hex(8)}"
      BoatProcurementOperation.create!(
        agent_placement: placement,
        placement_generation: placement.generation,
        requested_by:,
        public_id:,
        approval_reference:,
        sandbox_size: @config.sandbox_size,
        provider_name: "souls-house-#{public_id}"
      )
    end
  end

  # Mints enrollment authority, commits create intent, then sends the one
  # create request. Calling it again, concurrently or later, sends nothing.
  def submit!(operation)
    enrollment = nil
    script = nil
    claimed = operation.with_lock do
      next false unless operation.state == "planned"

      claimed_at = now
      enrollment, token = @minter.mint!(placement: operation.agent_placement, boat_operation_id: operation.id,
        now: claimed_at)
      # The plaintext token lives only in this local and the request body.
      script = @renderer.render(enrollment:, token:, rails_url: @config.rails_url,
        commands_enabled: @config.runner_commands)
      operation.transition_to!("create_in_flight", create_sent_at: claimed_at)
      true
    end
    return operation unless claimed

    if now > operation.create_sent_at + SUBMIT_DEADLINE
      settle!(operation, "create_in_flight", "needs_review", review_reason: "submit_deadline_passed")
      return operation.reload
    end

    begin
      sandbox = @client.create_sandbox(
        idempotency_key: operation.public_id,
        name: operation.provider_name,
        placement_id: operation.agent_placement_id.to_s,
        operation_id: operation.public_id,
        size: operation.sandbox_size,
        setup_script: script
      )
    rescue BoatClient::CreateOutcomeUnknown => e
      settle!(operation, "create_in_flight", "unknown", last_error_code: e.code)
    rescue BoatClient::Refused, BoatClient::NotConfigured => e
      # Raised by the client before any request left this process.
      refuse!(operation, enrollment, e.code)
    rescue BoatClient::Error => e
      if provider_refusal?(e)
        refuse!(operation, enrollment, e.code)
      else
        settle!(operation, "create_in_flight", "unknown", last_error_code: e.code)
      end
    rescue StandardError
      settle!(operation, "create_in_flight", "unknown", last_error_code: "unexpected_error")
      raise
    else
      record_sandbox!(operation, sandbox)
    end
    operation.reload
  end

  # Compares the operation with what Boat has and moves it at most one step.
  # Safe to run repeatedly and concurrently; never creates anything.
  def reconcile!(operation)
    operation.reload
    case operation.state
    when "create_in_flight", "unknown" then discover!(operation)
    when "reconciling" then check_setup!(operation)
    when "deleting" then check_deletion!(operation)
    end
    operation.reload
  rescue BoatClient::Error => e
    # A failed or partial read proves nothing; try again later.
    operation.update_columns(last_error_code: e.code, last_reconciled_at: now)
    operation
  end

  # Explicit admin cleanup. Only a sandbox this operation verified can be
  # deleted; the placement is kept, never removed.
  def request_delete!(operation, requested_by:)
    require_admin!(requested_by)
    operation.with_lock do
      unless %w[provisioned reconciling needs_review].include?(operation.state) && operation.provider_sandbox_id
        raise NotAllowed, "only an operation with a verified sandbox can be deleted"
      end

      operation.transition_to!("deleting", delete_requested_at: now, review_reason: nil)
    end
    send_delete!(operation)
    operation.reload
  end

  private

  def now = @clock.call

  def require_admin!(user)
    raise NotAuthorized, "installation admin required" unless user.is_a?(User) && user.is_site_admin?
  end

  # Only a validated refusal releases the reservation. CapacityUnavailable on
  # create (503 no_ready_machine, 429 limits) is documented as creating nothing.
  def provider_refusal?(error)
    return true if error.is_a?(BoatClient::CapacityUnavailable)

    error.status.to_i.between?(400, 499) && error.status.to_i != 408 && REFUSAL_CODES.include?(error.code)
  end

  def settle!(operation, from, to, **attributes)
    operation.with_lock do
      next false unless operation.state == from

      operation.transition_to!(to, last_reconciled_at: now, **attributes)
      true
    end
  end

  def refuse!(operation, enrollment, code)
    operation.with_lock do
      next unless operation.state == "create_in_flight"

      operation.transition_to!("refused", last_error_code: code, last_reconciled_at: now)
      enrollment&.revoke!(now:)
    end
  end

  def record_sandbox!(operation, sandbox)
    operation.with_lock do
      unless %w[create_in_flight unknown].include?(operation.state)
        # A sandbox that arrives for an operation no longer waiting for one
        # is recorded, never dropped.
        if operation.provider_sandbox_id.nil?
          operation.update_columns(provider_sandbox_id: sandbox.id,
            review_reason: "sandbox_arrived_after_close:#{operation.state}", last_reconciled_at: now)
          Rails.logger.error("[boat_procurement] sandbox #{sandbox.id} arrived for #{operation.public_id} in state #{operation.state}")
        end
        next
      end

      unless matches?(operation, sandbox)
        operation.transition_to!("needs_review", provider_sandbox_id: sandbox.id,
          review_reason: "created_sandbox_mismatch", last_reconciled_at: now)
        next
      end

      operation.transition_to!("reconciling", provider_sandbox_id: sandbox.id, last_error_code: nil,
        last_reconciled_at: now)
    end
  end

  # Zero, one or many: each is its own answer, never "pick one".
  def discover!(operation)
    sandboxes = @client.find_by_operation(operation.public_id)
    if sandboxes.size > 1
      settle!(operation, operation.state, "needs_review", review_reason: "multiple_sandboxes_found")
    elsif sandboxes.size == 1
      sandbox = sandboxes.first
      if matches?(operation, sandbox)
        record_sandbox!(operation, sandbox)
      else
        settle!(operation, operation.state, "needs_review", review_reason: "discovered_sandbox_mismatch")
      end
    elsif enrollment_expired?(operation)
      # The token in that request can no longer enroll, and it is never
      # re-minted. A sandbox may still exist: an operator decides.
      settle!(operation, operation.state, "needs_review", review_reason: "enrollment_expired_unresolved")
    else
      # Zero matches: still unknown. Not proof that nothing was created.
      settle!(operation, operation.state, "unknown")
    end
  end

  def check_setup!(operation)
    sandbox = @client.find_sandbox(operation.provider_sandbox_id)
    return settle!(operation, "reconciling", "needs_review", review_reason: "sandbox_missing") if sandbox.nil?
    return settle!(operation, "reconciling", "needs_review", review_reason: "sandbox_mismatch") unless matches?(operation, sandbox)
    return settle!(operation, "reconciling", "needs_review", review_reason: "sandbox_failed") if sandbox.failed?

    case sandbox.setup_status
    when SETUP_DONE
      sandbox.awake? ? provision!(operation, sandbox) : touch!(operation)
    when SETUP_FAILED
      settle!(operation, "reconciling", "needs_review", review_reason: "setup_failed")
    when "pending", "running"
      touch!(operation)
    else
      # We always send a setup script, so a sandbox without a status is not ours to trust.
      settle!(operation, "reconciling", "needs_review", review_reason: "setup_status_unrecognised")
    end
  end

  # Boat confirms the sandbox; the runner may now enroll. The placement learns
  # its sandbox but stays pending: provisioned is not ready.
  def provision!(operation, sandbox)
    operation.with_lock do
      next unless operation.state == "reconciling"

      enrollment = operation.runner_enrollment
      if enrollment.nil? || enrollment.revoked_at || now >= enrollment.expires_at
        operation.transition_to!("needs_review", review_reason: "enrollment_unusable", last_reconciled_at: now)
        next
      end

      enrollment.confirm_provider_sandbox!(sandbox.id)
      operation.agent_placement.update!(provider_sandbox_id: sandbox.id)
      operation.transition_to!("provisioned", provisioned_at: now, last_reconciled_at: now)
    end
  end

  def send_delete!(operation)
    @client.delete_sandbox(operation.provider_sandbox_id, placement_id: operation.agent_placement_id.to_s)
    check_deletion!(operation, resend: false)
  rescue BoatClient::Refused => e
    settle!(operation, "deleting", "needs_review", review_reason: "delete_refused", last_error_code: e.code)
  rescue BoatClient::Error => e
    # Lost or failed response: the sandbox may or may not be going. Reconcile.
    operation.update_columns(last_error_code: e.code, last_reconciled_at: now)
  end

  # Absence is verified by a 404 on the sandbox itself. A lost delete is sent
  # again on a later pass, never in a loop.
  def check_deletion!(operation, resend: true)
    sandbox = @client.find_sandbox(operation.provider_sandbox_id)
    if sandbox
      return send_delete!(operation) if resend

      return touch!(operation)
    end

    operation.with_lock do
      next unless operation.state == "deleting"

      placement = operation.agent_placement
      if placement.provider_sandbox_id == operation.provider_sandbox_id
        attributes = { provider_sandbox_id: nil }
        attributes[:state] = "failed" if placement.state == "ready"
        placement.update!(attributes)
      end
      operation.runner_enrollment&.revoke!(now:)
      operation.transition_to!("deleted", deleted_at: now, last_reconciled_at: now)
    end
  end

  def touch!(operation)
    operation.update_columns(last_reconciled_at: now)
  end

  def enrollment_expired?(operation)
    enrollment = operation.runner_enrollment
    enrollment.nil? || now >= enrollment.expires_at
  end

  # Identity and spec, not just a name.
  def matches?(operation, sandbox)
    sandbox.managed? &&
      sandbox.placement_id == operation.agent_placement_id.to_s &&
      sandbox.operation_id == operation.public_id &&
      sandbox.name == operation.provider_name &&
      sandbox.size == operation.sandbox_size
  end

end
