module Agents
  # Retires a resident that runs on the house's own host (no VM placement):
  # its volumes are removed and it leaves every conversation and backup path
  # for good. Its backups, messages and history stay. A deliberate transition
  # run by an operator at top level, never a hook or a job. A VM resident is
  # retired through its placement instead.
  #
  # Until 23 Nov 2026 a local resident could only be switched off, which
  # keeps its files by design, so throwaway 50 had no house path to retire
  # by (#969, jERNRJ).
  #
  # Order: fence, commit, then remove. The runtime becomes "deprecated"
  # (RETIRED_RUNTIMES fails closed everywhere) and the "agent_retired_local"
  # audit row records the exact container and volumes, both committed before
  # Docker deletes anything, so a Docker failure part way through never
  # returns a half-removed resident to the backup set. A partial cleanup
  # raises CleanupIncomplete; calling again finishes it, removing only what
  # that row names. Everything runs under the backup's quiesce lock, so a
  # backup cannot check a volume, lose it to this, and then mount (and so
  # recreate) it.
  class RetireLocal

    class Refused < StandardError; end
    class Busy < StandardError; end
    class CleanupIncomplete < StandardError; end

    ACTION = "agent_retired_local"

    # Retired by this class: deprecated, with the fence's audit row. The
    # row, not any prose on the agent, is the authority to resume removal.
    def self.retired_local?(agent)
      agent.runtime == "deprecated" && fence_record(agent).present?
    end

    def self.retired_local_ids
      AuditLog.where(action: ACTION, auditable_type: "Agent").select(:auditable_id)
    end

    def self.fence_record(agent)
      AuditLog.where(action: ACTION, auditable: agent).order(:id).first
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
      # Inside an enclosing transaction the fence would be a savepoint, gone
      # with the caller's rollback after the volumes are (Mira, #1105).
      raise Refused, "Retirement must not run inside an open transaction" if Agent.connection.transaction_open?

      connection = ActiveRecord::Base.connection
      unless connection.select_value(Backup::AgentRestic.quiesce_lock_sql("pg_try_advisory_lock", agent))
        raise Busy, "A backup or runtime roll holds this resident; try again"
      end
      begin
        record = fence!
        remove!(record)
      ensure
        connection.select_value(Backup::AgentRestic.quiesce_lock_sql("pg_advisory_unlock", agent))
      end
    end

    private

    attr_reader :agent, :reason, :by

    # Commits the fence (or finds the committed one) and returns its record.
    def fence!
      Agent.transaction do
        agent.lock!
        check_quiet!
        # Before any Docker call: the endpoint is local and, on a namespaced
        # instance, the container and volumes carry this checkout's labels.
        resources.verify_existing!
        if agent.runtime == "deprecated"
          record = self.class.fence_record(agent)
          refuse!("is deprecated but was not retired as a local resident") unless record
          unless record.data["volumes"] == volumes.transform_keys(&:to_s) && record.data["container"] == resources.container
            refuse!("no longer maps to the volumes its retirement recorded")
          end
          next record
        end

        refuse!("is not offline (runtime #{agent.runtime})") unless agent.runtime == "offline"
        refuse!("has a running container") if container_state == :running

        agent.update!(runtime: "deprecated", deprecated_at: Time.current,
          deprecation_reason: "Retired shared-host resident: #{reason}", trigger_bearer_token: nil)
        AuditLog.create!(action: ACTION, user: by, account: agent.account, auditable: agent,
          data: { "reason" => reason, "container" => resources.container, "volumes" => volumes.transform_keys(&:to_s) })
      end
    end

    # Rechecked on every call, first retirement or retry.
    def check_quiet!
      refuse!("has no uuid, so no volumes of its own") if agent.uuid.blank?
      refuse!("has a VM placement; retire it through its placement") if AgentPlacement.exists?(agent_id: agent.id)
      # An import's retry or trust check can write the runtime back to
      # offline (GithubResidentImportJob), which would lift the fence. Not
      # retirable here until imports share this admission (Mira, #1105).
      refuse!("came from a GitHub import; not retirable yet") if agent.github_resident_import_id.present?
      refuse!("is still switched on") if agent.active?
      refuse!("has active runtime work") if agent.agent_runtime_interactions.active.exists?
    end

    # Removes the container (stopped; a running one was refused) and each
    # volume the fence recorded, then reads every one back as absent.
    def remove!(record)
      names = record.data.fetch("volumes").values
      container = record.data.fetch("container")
      case container_state(container)
      when :running then raise CleanupIncomplete, "The container is running again; not removed"
      when :present
        _, err, status = Open3.capture3("docker", "rm", container)
        raise CleanupIncomplete, "Could not remove the container: #{err.to_s.squish.last(200)}" unless status.success?
      end

      removed = []
      names.each do |volume|
        next if volume_state(volume) == :absent

        _, err, status = Open3.capture3("docker", "volume", "rm", volume)
        unless status.success? || err.to_s.match?(/no such volume/i)
          raise CleanupIncomplete, "Could not remove #{volume}: #{err.to_s.squish.last(200)}"
        end
        removed << volume
      end
      remaining = names.reject { |volume| volume_state(volume) == :absent }
      raise CleanupIncomplete, "Still present after removal: #{remaining.join(', ')}" if remaining.any?

      if removed.any?
        AuditLog.create!(action: "agent_retired_local_cleaned", user: by, account: agent.account, auditable: agent,
          data: { "removed" => removed })
      end
      removed
    end

    def refuse!(why)
      raise Refused, "#{agent.name} #{why}"
    end

    def resources
      @resources ||= Agents::Resources.new(agent)
    end

    def volumes
      resources.volumes
    end

    def container_state(container = resources.container)
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
