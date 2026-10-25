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
  TRUST_CHECK_ATTEMPTS = 3
  TRUST_RELEASED = "Its server was released after waiting #{Agents::VmBirthPolicy::BIRTH_DEADLINE.in_minutes.to_i} minutes " \
                   "for runtime trust. Its reviewed home is kept: Retry activation orders a new server, and trust " \
                   "must be granted on that one.".freeze

  class Failed < StandardError; end

  def perform(agent_id)
    placement_id = AgentPlacement.where(agent_id: agent_id).pick(:id)
    return :done unless placement_id

    self.class.exclusively(placement_id) { advance(agent_id) }
  end

  # One lifecycle lock per placement, shared by the birth and its cleanup, so
  # a late order can never cross cleanup's decision to retire. Runs the block
  # only if no other run holds it; otherwise does nothing, and the run holding
  # it, or the next sweep, carries on. The lock SQL is side-effecting, so it
  # runs uncached, and acquire, block and unlock share one leased connection.
  def self.exclusively(placement_id, lock_class: LOCK_CLASS)
    key = "#{Integer(lock_class)}, #{Integer(placement_id)}"
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      acquired = connection.uncached { connection.select_value("SELECT pg_try_advisory_lock(#{key})") }
      return :busy unless acquired

      begin
        yield
      ensure
        connection.uncached { connection.select_value("SELECT pg_advisory_unlock(#{key})") }
      end
    end
  end

  private

  def advance(agent_id)
    agent = Agent.find_by(id: agent_id)
    return :done if agent.nil?
    if agent.runtime_ready_at.present?
      return reapproval_pending?(agent) ? reapprove!(agent) : :done
    end

    placement = Agents::RemoteRuntime.placement_for(agent)
    return :done unless placement&.vm_birth?
    return :done if placement.cleanup_requested? || %w[failed retired].include?(placement.state)

    if placement.birth_deadline_at && Time.current >= placement.birth_deadline_at
      raise Failed, "the birth did not finish before its deadline"
    end

    step!(agent, placement)
  rescue Failed, CloudProcurement::NotAllowed, Agents::VmSeed::Unavailable, Agents::RemoteRuntime::Unavailable,
         Agent::RuntimeAvailability::Unavailable => e
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
    return :wait unless github_import?(placement) ? trusted?(agent, placement) : true
    return :wait unless started?(agent, placement)
    return :wait unless backed_up?(placement)

    finish!(agent)
    :done
  end

  # One purchase per birth, or per attempt of a retried activation: only a
  # purchase made for the placement's current generation counts, so the last
  # attempt's deleted server is never read as this one's. A refusal or
  # anything an operator must look at fails the birth; cleanup then
  # reconciles whatever might exist.
  def server_ready?(placement)
    operation = placement.cloud_procurement_operations.where(placement_generation: placement.generation).order(:id).last ||
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

  # A GitHub import starts only once Chaos in its own runtime home trusts it
  # (docs/2026-10-10-vm-imports.md, points 4 and 5): the same check the house
  # runs locally, run by the runner. Untrusted, it waits with its server in
  # needs_runtime_trust, inactive and paused, for a person to grant trust on
  # Chaos's own screen there and retry; the deadline bounds that paid wait.
  # Nothing about trust is inferred here: only the runner's "trusted" counts.
  def trusted?(agent, placement)
    checks = RunnerCommand.where(agent_placement_id: placement.id, kind: "check_runtime_trust", generation: placement.generation)
    last = checks.order(:id).last
    if last.nil?
      Agents::RemoteRuntime.check_runtime_trust!(agent)
      return false
    end

    request = agent.github_resident_import
    case Agents::RemoteRuntime.runtime_trust_outcome(last)
    when :trusted
      request.update!(status: "provisioning", last_error: nil) if request.status == "needs_runtime_trust"
      true
    when :pending then false
    when :untrusted
      unless request.status == "needs_runtime_trust"
        request.update!(status: "needs_runtime_trust", last_error: nil)
        agent.update_columns(active: false, paused: true, runtime: "offline", updated_at: Time.current)
      end
      false
    when :unsupported then raise Failed, "its runtime image does not support managed GitHub imports"
    else
      raise Failed, "the runtime trust check failed (#{last.result&.dig('error') || last.state})" if checks.count >= TRUST_CHECK_ATTEMPTS

      Agents::RemoteRuntime.check_runtime_trust!(agent)
      false
    end
  end

  # A ready GitHub import approved again (GithubResidentImportJob sent a
  # fresh trust check). As on the house: trusted, the runtime is refreshed
  # with the approved values between turns (begin_refresh!, the credential
  # and service restart) and the request is ready again; not trusted, the
  # request waits in needs_runtime_trust and the resident is paused. A
  # refresh refused as busy is tried again by the next sweep. Nothing here
  # fails the birth or touches its server's lifecycle.
  def reapproval_pending?(agent)
    placement = Agents::RemoteRuntime.placement_for(agent)
    github_import?(placement) && placement.state == "ready" && agent.github_resident_import&.status == "provisioning"
  end

  def reapprove!(agent)
    placement = Agents::RemoteRuntime.placement_for(agent)
    request = agent.github_resident_import
    last = RunnerCommand.where(agent_placement_id: placement.id, kind: "check_runtime_trust", generation: placement.generation)
      .order(:id).last
    case last && Agents::RemoteRuntime.runtime_trust_outcome(last)
    when :pending then :wait
    when :trusted
      request.require_approval!
      # Ready only once the restart carrying the approved values is
      # confirmed, as the house's own recreate is done before it says ready.
      refreshing = RunnerCommand.where(agent_placement_id: placement.id, kind: "start_resident", generation: placement.generation)
        .where("id > ?", last.id).exists?
      unless refreshing
        return :wait if Agents::RemoteRuntime.begin_refresh!(agent) == :busy

        RemoteRefreshSettleJob.set(wait: RemoteRefreshSettleJob::RECHECK_AFTER).perform_later(placement.id)
        return :wait
      end
      case Agents::RemoteRuntime.settle_refresh!(placement)
      when :done
        agent.update_columns(active: true, paused: false, updated_at: Time.current)
        request.update!(status: "ready", last_error: nil)
        :done
      when :held
        # Its turns stay held by the refresh (an operator can release it).
        request.update!(status: "failed", last_error: "Its runtime restart with the newly approved values did not " \
                                                    "settle: #{placement.reload.refresh_last_error.presence || 'no detail'}".first(1000))
        :done
      else :wait
      end
    when :untrusted
      agent.update_columns(active: false, paused: true, updated_at: Time.current)
      request.update!(status: "needs_runtime_trust", last_error: nil)
      :done
    else
      agent.update_columns(active: false, paused: true, updated_at: Time.current)
      request.update!(status: "failed", last_error: "The runtime trust check on its server did not answer trusted " \
                                                  "(#{last&.result&.dig('error') || last&.result&.dig('result', 'trust') || 'no check'}).")
      :done
    end
  rescue Agent::RuntimeAvailability::Unavailable => e
    agent.update_columns(active: false, paused: true, updated_at: Time.current)
    request&.update!(status: "failed", last_error: e.message.to_s.first(1000))
    :done
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

  # A birth is oriented. A migration, an archive import and a GitHub import
  # are not. An archive import (docs/2026-10-10-vm-imports.md,
  # "After seeding"): it arrives with its own home, and only now, after its
  # first verified backup, does Activate's request take effect. Imported
  # schedules stay off until someone turns them on.
  def finish!(agent)
    now = Time.current
    attributes = { runtime: "external", health_state: "healthy", consecutive_health_failures: 0,
      runtime_ready_at: now, identity_seeded_at: agent.identity_seeded_at || now,
      sandbox_last_error: nil, sandbox_last_error_at: nil }
    if migration?(agent.placement)
      # A resident that already lived on the house (#426): no orientation and
      # nothing reset. Its own schedule choice is kept, and runtime_ready_at
      # is set afresh only now, after its first verified backup here.
      agent.update_columns(attributes.merge(active: true, paused: false, updated_at: now))
      HomeResidentRoster.refresh!([ agent.account_id ])
      AuditLog.create!(action: "vm_migration_ready", account: agent.account, auditable: agent,
        data: { "placement_id" => agent.placement.id, "generation" => agent.placement.generation })
    elsif archive_import?(agent) || github_import?(agent.placement)
      # Direct columns, as the local activation does: no model-change orientation callbacks.
      agent.update_columns(attributes.merge(active: true, paused: false, scheduled_wakes_enabled: false, updated_at: now))
      agent.github_resident_import&.update!(status: "ready", last_error: nil)
      HomeResidentRoster.refresh!([ agent.account_id ])
    else
      agent.update!(attributes)
      OrientNewAgentJob.perform_later(agent.id)
    end
  end

  def archive_import?(agent) = Agents::RemoteRuntime.placement_for(agent)&.kind == "archive_import"
  def github_import?(placement) = placement&.kind == "github_import"
  def migration?(placement) = placement&.kind == "migration"

  # The birth stops here: no start, no orientation. The resident keeps its
  # record and says why; the server goes to cleanup, which keeps it counted
  # against the cap until the provider confirms it is gone.
  def fail_birth!(agent, placement, reason)
    return if agent.nil?

    if migration?(placement)
      # Still inactive and paused, its stage kept and its house home untouched
      # (#426). It is not started on the house here: a person chooses between
      # trying the move again and Return to house (Agents::VmMigration).
      agent.update_columns(active: false, paused: true, runtime: "offline", health_state: "unhealthy",
        sandbox_last_error: "Moving to its own server failed: #{reason}. Its home is still on the house, untouched".first(1000),
        sandbox_last_error_at: Time.current, updated_at: Time.current)
    elsif archive_import?(agent)
      # Still inactive and paused, its stage kept; Activate can be asked again.
      agent.update!(runtime: "offline", health_state: "unhealthy",
        sandbox_last_error: "Activation on its own server failed: #{reason}".first(1000), sandbox_last_error_at: Time.current)
    elsif github_import?(placement)
      # Inactive and paused, its reviewed home and import record kept. Waiting
      # for trust past the deadline is not a failure of the import: it keeps
      # its retry; anything else fails it, plainly.
      agent.update_columns(active: false, paused: true, runtime: "offline", health_state: "unhealthy",
        sandbox_last_error: "Starting on its own server failed: #{reason}".first(1000), sandbox_last_error_at: Time.current,
        updated_at: Time.current)
      request = agent.github_resident_import
      if request&.status == "needs_runtime_trust"
        request.update!(last_error: TRUST_RELEASED)
      elsif request
        request.update!(status: "failed", last_error: "Starting on its own server failed: #{reason}".first(1000))
      end
    else
      agent.update!(health_state: "unhealthy", sandbox_last_error: "VM birth failed: #{reason}".first(1000),
        sandbox_last_error_at: Time.current)
    end
    return if placement.nil?

    placement.update!(state: "failed") unless %w[failed retired].include?(placement.state)
    placement.request_cleanup!("birth_failed: #{reason}")
    VmCleanupJob.perform_later(placement.id)
    Rails.logger.error("[vm_birth] agent=#{agent.id} placement=#{placement.id} failed: #{reason}")
  end

end
