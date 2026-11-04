# Reboots a resident's VM onto the kernel unattended-upgrades installed.
#
# Debian installs new kernels on the VMs but nothing ever reboots them: on
# 4 Nov Janis's VM was still on 6.12.107 two days after 6.12.115 (DSA-6602)
# was installed, with public sshd, and Alanis's was on 113. Both were rebooted
# by hand.
#
# The runner reports kernel_running, kernel_installed and reboot_required
# (and since when). On each heartbeat the house decides:
#
#   * not required, or a runner that can't reboot: nothing.
#   * required: reboot when the resident is idle in the house's own view (no pending
#     turn, no active interaction, no lifecycle command in flight, no backup
#     hold, no credential refresh, no runtime roll), checked under the turn
#     admission gate, so no turn can be admitted between the check and the
#     command. Never forced: a busy resident is tried again on a later beat.
#     Most of Debian stable's kernel updates carry security fixes, and
#     telling the rest apart would cost runner bytes user_data doesn't have,
#     so there is no weekly wait: the first idle moment is the window.
#
# The runner checks again what it can see (Debian still asks; no `chaos
# exec` on the host) and refuses otherwise; it answers first, then reboots.
# A turn that arrives meanwhile waits in the queue (ResidentTurn.admit!) until
# the heartbeat shows the fresh boot, or BOOT_GRACE passes. The fresh boot is
# recorded as an audit entry (the latch), and the resident's home account is
# told in one quiet line.
module KernelReboot

  KIND = "reboot_host".freeze
  RECORDED = "vm_kernel_rebooted".freeze
  # After a refused, failed or unknown attempt.
  RETRY_AFTER = 15.minutes
  # A reboot that answered done but whose boot the house hasn't seen holds
  # turns, and further attempts, this long.
  BOOT_GRACE = 15.minutes
  RELEASE = /\A[0-9A-Za-z.+_\-~]{1,100}\z/

  module_function

  def facts_of(enrollment)
    enrollment.last_facts.is_a?(Hash) ? enrollment.last_facts : {}
  end

  def required?(facts)
    facts["reboot_required"] == true && facts["reboot_host"].is_a?(Integer) && facts["reboot_host"] >= 1
  end

  # Queues reboot_host when it is required and the resident is idle. Never raises:
  # a heartbeat must not fail because of it.
  def offer!(enrollment, now: Time.current)
    return unless offer?(enrollment, now:)

    agent = enrollment.agent_placement.agent
    ResidentTurn.transaction do
      ResidentTurn.connection.execute("SELECT pg_advisory_xact_lock(#{Agents::RemoteRuntime::TURN_GATE})")
      agent.with_lock do
        return unless idle?(agent, enrollment)

        RunnerCommand.enqueue!(enrollment:, kind: KIND, payload: {})
      end
    end
  rescue StandardError => e
    Rails.logger.warn("[kernel_reboot] offer failed for #{enrollment.public_id}: #{e.class}: #{e.message}")
    nil
  end

  def offer?(enrollment, now: Time.current)
    return false unless enrollment.enrolled_at && enrollment.revoked_at.nil?

    placement = AgentPlacement.uncached { AgentPlacement.find_by(id: enrollment.agent_placement_id) }
    return false unless placement&.backend == "hetzner_cloud" && placement.state == "ready"

    facts = facts_of(enrollment)
    return false unless required?(facts)

    last = enrollment.commands.where(kind: KIND).order(:id).last
    return true unless last
    return false unless last.terminal?
    if last.state == "done"
      return true if recorded?(last)

      return last.finished_at <= now - BOOT_GRACE
    end
    last.finished_at <= now - RETRY_AFTER
  end

  # The house's view of the resident: nothing running, nothing waiting.
  def idle?(agent, enrollment)
    return false if ResidentTurn.pending.where(agent_id: agent.id).exists?
    return false if Backup::VmResident.busy?(agent) || Backup::VmResident.held?(agent)
    return false if Agents::RemoteRuntime.refresh_pending?(agent)
    return false if agent.runtime_roll_started_at.present?

    !enrollment.commands.where(state: %w[queued delivered]).exists?
  end

  # On every heartbeat: a reboot_host answered done, then a boot after it was
  # issued, is a completed reboot. Recorded once, the owner told once, and the
  # turns that waited are dispatched.
  def observe!(enrollment, now: Time.current)
    command = enrollment.commands.where(kind: KIND, state: "done").order(:id).last
    return unless command && !recorded?(command)

    facts = facts_of(enrollment)
    uptime = facts["uptime_seconds"]
    return unless uptime.is_a?(Integer) && uptime >= 0

    booted_at = now - uptime.seconds
    return unless booted_at >= command.created_at

    agent = enrollment.agent_placement.agent
    before = command.result&.dig("result", "kernel_running")
    after = facts["kernel_running"]
    record!(agent, command, before:, after:, booted_at:)
    ResidentTurnDispatchJob.perform_later
  rescue StandardError => e
    Rails.logger.warn("[kernel_reboot] observe failed for #{enrollment.public_id}: #{e.class}: #{e.message}")
    nil
  end

  def recorded?(command)
    AuditLog.where(action: RECORDED).where("data->>'command_id' = ?", command.public_id).exists?
  end

  # Agents whose turns wait: a reboot queued or delivered, or answered done
  # and not yet seen booted, within BOOT_GRACE.
  def holding_agent_ids(now: Time.current)
    rows = RunnerCommand.joins(:agent_placement).where(kind: KIND)
      .where("runner_commands.state IN ('queued', 'delivered') OR " \
             "(runner_commands.state = 'done' AND runner_commands.finished_at > ?)", now - BOOT_GRACE)
      .pluck("agent_placements.agent_id", "runner_commands.public_id")
    return Set.new if rows.empty?

    done = AuditLog.where(action: RECORDED).where("data->>'command_id' IN (?)", rows.map(&:last))
      .pluck(Arel.sql("data->>'command_id'")).to_set
    rows.reject { |_agent_id, public_id| done.include?(public_id) }.map(&:first).to_set
  end

  def record!(agent, command, before:, after:, booted_at:)
    # Runner-reported strings reach a message and an audit row: only a
    # kernel-release shape passes.
    before = nil unless before.is_a?(String) && RELEASE.match?(before)
    after = nil unless after.is_a?(String) && RELEASE.match?(after)
    Agent.transaction do
      chat = agent.account.chats.create_with_message!(
        { title: "#{agent.name}'s server restarted for a kernel update", manual_responses: true },
        agent_ids: [ agent.id ], automatic_response: false
      )
      chat.messages.create!(role: "system", content: notice_text(agent, after, booted_at))
      AuditLog.create!(user: nil, account: agent.account, action: RECORDED, auditable: agent,
        data: { command_id: command.public_id, kernel_before: before, kernel_after: after,
                booted_at: booted_at.iso8601, chat_id: chat.id })
    end
  end

  def notice_text(agent, kernel, at)
    zone = ActiveSupport::TimeZone[agent.account.owner&.timezone.to_s] || ActiveSupport::TimeZone["UTC"]
    back_on = kernel ? ", back on Linux #{kernel}" : ""
    "[System Notice] #{agent.name}'s server restarted for a kernel update at " \
      "#{at.in_time_zone(zone).strftime('%-d %b %H:%M %Z')}#{back_on}. Nothing for you to do."
  end

end
