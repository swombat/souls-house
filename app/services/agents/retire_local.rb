module Agents
  # Retires a resident that runs on the house's own host (no VM placement):
  # its volumes are removed and it leaves every conversation and backup path
  # for good. Its backups, messages and history stay. A deliberate transition
  # run by an operator, never a hook or a job. A VM resident is retired
  # through its placement instead.
  #
  # Until 23 Nov 2026 a local resident could only be switched off, which
  # keeps its files by design, so throwaway 50 had no house path to retire
  # by (#969, jERNRJ).
  #
  # Order: fence, then remove. The runtime becomes "deprecated" first
  # (RETIRED_RUNTIMES fails closed everywhere), so a Docker failure part way
  # through never returns a half-removed resident to the backup set. A
  # partial cleanup raises CleanupIncomplete; calling again finishes it.
  # Everything runs under the backup's quiesce lock, so a backup cannot
  # check a volume, lose it to this, and then mount (and so recreate) it.
  class RetireLocal

    class Refused < StandardError; end
    class Busy < StandardError; end
    class CleanupIncomplete < StandardError; end

    REASON_PREFIX = "Retired shared-host resident"

    def self.retired_local?(agent)
      agent.runtime == "deprecated" && agent.deprecation_reason.to_s.start_with?(REASON_PREFIX)
    end

    def self.call(agent, reason:, by: nil)
      new(agent, reason:, by:).call
    end

    def initialize(agent, reason:, by: nil)
      raise ArgumentError, "A reason is required" if reason.blank?

      @agent = agent
      @reason = reason
      @by = by
    end

    # Returns the names of the volumes it removed (none on a call that only
    # confirms an earlier retirement is complete).
    def call
      connection = ActiveRecord::Base.connection
      unless connection.select_value(Backup::AgentRestic.quiesce_lock_sql("pg_try_advisory_lock", agent))
        raise Busy, "A backup or runtime roll holds this resident; try again"
      end
      begin
        fence!
        remove!
      ensure
        connection.select_value(Backup::AgentRestic.quiesce_lock_sql("pg_advisory_unlock", agent))
      end
    end

    private

    attr_reader :agent, :reason, :by

    def fence!
      Agent.transaction do
        agent.lock!
        fence_locked! unless self.class.retired_local?(agent)
      end
    end

    def fence_locked!
      refuse!("has a VM placement; retire it through its placement") if AgentPlacement.exists?(agent_id: agent.id)
      refuse!("is not offline (runtime #{agent.runtime})") unless agent.runtime == "offline"
      refuse!("is still switched on") if agent.active?
      refuse!("has active runtime work") if agent.agent_runtime_interactions.active.exists?
      refuse!("has no uuid, so no volumes of its own") if agent.uuid.blank?
      refuse!("has a running container") if container_state == :running

      agent.update!(runtime: "deprecated", deprecated_at: Time.current,
        deprecation_reason: "#{REASON_PREFIX}: #{reason}", trigger_bearer_token: nil)
      AuditLog.create!(action: "agent_retired_local", user: by, account: agent.account, auditable: agent,
        data: { "reason" => reason, "volumes" => volumes.values })
    end

    # Removes the container (stopped; a running one was refused) and each of
    # the resident's mapped volumes, then reads every one back as absent.
    def remove!
      Agents::DockerLocalGuard.check!
      case container_state
      when :running then raise CleanupIncomplete, "The container is running again; not removed"
      when :present
        _, err, status = Open3.capture3("docker", "rm", container)
        raise CleanupIncomplete, "Could not remove the container: #{err.to_s.squish.last(200)}" unless status.success?
      end

      removed = []
      volumes.each_value do |volume|
        case volume_state(volume)
        when :absent then next
        when :present
          _, err, status = Open3.capture3("docker", "volume", "rm", volume)
          unless status.success? || err.to_s.match?(/no such volume/i)
            raise CleanupIncomplete, "Could not remove #{volume}: #{err.to_s.squish.last(200)}"
          end
          removed << volume
        end
      end
      remaining = volumes.values.reject { |volume| volume_state(volume) == :absent }
      raise CleanupIncomplete, "Still present after removal: #{remaining.join(', ')}" if remaining.any?

      AuditLog.create!(action: "agent_retired_local_cleaned", user: by, account: agent.account, auditable: agent,
        data: { "removed" => removed }) if removed.any?
      removed
    end

    def refuse!(why)
      raise Refused, "#{agent.name} #{why}"
    end

    def volumes
      @volumes ||= Agents::Resources.new(agent).volumes
    end

    def container
      Agents::Resources.new(agent).container
    end

    def container_state
      out, err, status = Open3.capture3("docker", "container", "inspect", "--format", "{{.State.Running}}", container)
      return (out.strip == "false" ? :present : :running) if status.success?
      return :absent if err.to_s.match?(/no such (container|object)/i)

      raise CleanupIncomplete, "Cannot inspect the resident's container"
    end

    def volume_state(volume)
      _, err, status = Open3.capture3("docker", "volume", "inspect", volume)
      return :present if status.success?
      return :absent if err.to_s.match?(/no such volume/i)

      raise CleanupIncomplete, "Cannot inspect #{volume}"
    end

  end
end
