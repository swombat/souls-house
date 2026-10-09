# Brings a resident born on its own VM to life (#246 slice 5,
# docs/2026-10-09-vm-hosted-new-residents.md). Each run reads current state
# and moves at most a step or two. VmBirthSweepJob runs it again every minute
# until the birth is done or has failed, and runs for one agent never overlap
# (a per-agent advisory lock), so it is safe to run twice or after a restart:
#
#   order the server -> runner enrolled -> seed the home -> mark ready, start
#   -> first backup verified -> runtime_ready_at, orientation
#
# What it protects, and from whom: the resident from being treated as alive
# before its home is recoverable (no turn is dispatched until the first
# backup is verified, see RemoteRuntime.enrollment_for), and the house's money
# from a birth that never finishes (a deadline, after which the birth fails
# and its server goes to VmCleanupJob).
class ProvisionVmAgentJob < ApplicationJob

  queue_as :default

  LOCK_CLASS = 0x5646_4242
  # Replaced in tests with a CloudProcurement over a fake provider.
  class_attribute :procurement_factory, default: -> { CloudProcurement.from_credentials }
  SEED_ATTEMPTS = 3
  BACKUP_ATTEMPTS = 3

  class Failed < StandardError; end

  def perform(agent_id)
    self.class.exclusively(agent_id) { advance(agent_id) }
  end

  # Runs the block only if no other run holds this lock (one per agent, or
  # per placement for cleanup); otherwise does nothing, and the run holding
  # it, or the next sweep, carries on.
  def self.exclusively(id, lock_class: LOCK_CLASS)
    connection = ActiveRecord::Base.connection
    key = "#{Integer(lock_class)}, #{Integer(id)}"
    return :busy unless connection.select_value("SELECT pg_try_advisory_lock(#{key})")

    begin
      yield
    ensure
      connection.select_value("SELECT pg_advisory_unlock(#{key})")
    end
  end

  private

  def advance(agent_id)
    agent = Agent.find_by(id: agent_id)
    return :done if agent.nil? || agent.runtime_ready_at.present?

    placement = Agents::RemoteRuntime.placement_for(agent)
    return :done unless placement&.vm_birth?
    return :done if placement.cleanup_requested? || %w[failed retired].include?(placement.state)

    if placement.birth_deadline_at && Time.current >= placement.birth_deadline_at
      raise Failed, "the birth did not finish before its deadline"
    end

    step!(agent, placement)
  rescue Failed, CloudProcurement::NotAllowed, Agents::VmSeed::Unavailable, Agents::RemoteRuntime::Unavailable => e
    fail_birth!(agent, placement, e.message)
    :failed
  rescue StandardError => e
    # Anything unexpected is tried again by the next sweep; the deadline
    # bounds how long that can go on.
    Rails.logger.error("[vm_birth] agent=#{agent_id} step error, will retry: #{e.class}: #{e.message}")
    :wait
  end

  def procurement
    @procurement ||= self.class.procurement_factory.call
  end

  def step!(agent, placement)
    return :wait unless server_ready?(placement)
    return :wait unless enrolled?(placement)
    return :wait unless seeded?(agent)
    return :wait unless started?(agent, placement)
    return :wait unless backed_up?(placement)

    finish!(agent)
    :done
  end

  # One purchase per birth. A refusal or anything an operator must look at
  # fails the birth; cleanup then reconciles whatever might exist.
  def server_ready?(placement)
    operation = placement.cloud_procurement_operations.order(:id).last ||
      procurement.plan_for_vm_birth!(placement:)

    case operation.reload.state
    when "planned" then procurement.submit!(operation)
    when "create_in_flight", "unknown", "reconciling" then procurement.reconcile!(operation)
    end

    case operation.reload.state
    when "refused" then raise Failed, "the server order was refused (#{operation.last_error_code || 'no code'})"
    when "needs_review" then raise Failed, "the server order needs review (#{operation.review_reason})"
    when "deleting", "deleted" then raise Failed, "the server is being deleted"
    end
    operation.state == "provisioned"
  end

  def enrolled?(placement)
    RunnerEnrollment.where(agent_placement_id: placement.id, revoked_at: nil).where.not(enrolled_at: nil)
      .order(enrolled_at: :desc).first&.healthy? || false
  end

  def seeded?(agent)
    seed = Agents::VmSeed.new(agent)
    status = seed.status
    return true if status.done?

    if status.none? || (seed.retryable?(status) && status.attempts < SEED_ATTEMPTS)
      seed.issue!
    elsif status.failed?
      raise Failed, "the home could not be seeded (#{status.error})"
    end
    false
  end

  # The placement becomes ready only now, after a seeded home, and the start
  # pins the exact image the house would run locally. Ready still dispatches
  # nothing: runtime_ready_at is set only after the first verified backup.
  def started?(agent, placement)
    start = RunnerCommand.where(agent_placement_id: placement.id, kind: "start_resident",
      generation: placement.generation).order(:id).last
    if start.nil?
      placement.update!(state: "ready") unless placement.state == "ready"
      Agents::RemoteRuntime.start!(agent)
      return false
    end

    case start.state
    when "done" then true
    when "queued", "delivered" then false
    else raise Failed, "the resident did not start (#{start.state}: #{start.result&.dig('error') || 'no detail'})"
    end
  end

  # Slice 4's seam: Backup::VmResident issues the backup (refusing unless the
  # resident is idle, holding turns until it settles) and verifies it from
  # storage, not from the runner's say-so.
  def backed_up?(placement)
    command = placement.first_backup_command_id && RunnerCommand.find_by(id: placement.first_backup_command_id)
    command ||= adopt_pending_backup!(placement)
    if command.nil?
      issue_backup!(placement)
      return false
    end

    status = Backup::VmResident.status(command:)
    case status[:state].to_s
    when "verified" then true
    when "pending" then false
    else
      # A failed backup that kept its hold left the runtime in a state nobody
      # knows (paused or not). Containment is deleting the VM, not retrying.
      if Backup::VmResident.held?(placement.agent)
        raise Failed, "the first backup left the resident in an unknown state (#{status[:reason] || 'no detail'})"
      end
      attempts = RunnerCommand.where(agent_placement_id: placement.id, kind: command.kind,
        generation: placement.generation).count
      raise Failed, "the first backup failed (#{status[:reason] || 'no detail'})" if attempts >= BACKUP_ATTEMPTS

      issue_backup!(placement)
      false
    end
  end

  # Something else (the first graph checkpoint) may have started a backup for
  # this resident already; its outcome is the one that counts.
  def adopt_pending_backup!(placement)
    return nil unless defined?(VmBackup) && Backup::VmResident.respond_to?(:held?) && Backup::VmResident.held?(placement.agent)

    command = VmBackup.holding.find_by(agent_id: placement.agent_id)&.runner_command
    placement.update!(first_backup_command_id: command.id) if command
    command
  end

  def issue_backup!(placement)
    raise Failed, "VM backups are not available on this house" unless Backup.const_defined?(:VmResident)

    command = Backup::VmResident.issue!(placement:)
    placement.update!(first_backup_command_id: command.id)
  end

  def finish!(agent)
    now = Time.current
    agent.update!(runtime: "external", health_state: "healthy", consecutive_health_failures: 0,
      runtime_ready_at: now, identity_seeded_at: agent.identity_seeded_at || now,
      sandbox_last_error: nil, sandbox_last_error_at: nil)
    OrientNewAgentJob.perform_later(agent.id)
  end

  # The birth stops here: no start, no orientation. The resident keeps its
  # record and says why; the server goes to cleanup, which keeps it counted
  # against the cap until the provider confirms it is gone.
  def fail_birth!(agent, placement, reason)
    return if agent.nil?

    agent.update!(health_state: "unhealthy", sandbox_last_error: "VM birth failed: #{reason}".first(1000),
      sandbox_last_error_at: Time.current)
    return if placement.nil?

    placement.update!(state: "failed") unless %w[failed retired].include?(placement.state)
    placement.request_cleanup!("birth_failed: #{reason}")
    VmCleanupJob.perform_later(placement.id)
    Rails.logger.error("[vm_birth] agent=#{agent.id} placement=#{placement.id} failed: #{reason}")
  end

end
