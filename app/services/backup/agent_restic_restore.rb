module Backup
  class AgentResticRestore

    class RestoreError < StandardError; end

    def self.restore_all!
      if LocalInstance.current.namespace
        raise RestoreError, "Shared agent restore is disabled for secondary/test instances"
      end
      ensure_docker_available!
      Backup::LocalAgentRuntimeImage.ensure_current! if Rails.env.development?

      Agent.externally_hosted.where.not(uuid: nil).find_each do |agent|
        new(agent).restore!
      end
    end

    def self.ensure_docker_available!
      stdout, stderr, status = Open3.capture3("docker", "info", "--format", "{{.ServerVersion}}")
      return true if status.success? && stdout.strip.present?

      detail = stderr.presence || stdout.presence || "unknown Docker error"
      raise RestoreError, "Docker daemon is not reachable. Start Docker and retry: #{detail.strip}"
    end

    def initialize(agent)
      @agent = agent
    end

    def restore!(wake: true)
      if LocalInstance.current.namespace && !Backup::LocalRepository.enabled?
        raise RestoreError, "Restoring shared agent data into secondary/test instances is not supported"
      end
      Agents::Resources.new(agent).verify_existing!
      Backup::LocalRepository.new(agent) if Backup::LocalRepository.enabled?
      snapshot = agent.agent_backup_snapshots.where(ok: true).order(taken_at: :desc).first
      raise RestoreError, "No successful agent backup is recorded for #{agent.name}" unless snapshot
      if agent.memory_erased_at && snapshot.taken_at <= agent.memory_erased_at && snapshot.graph_checkpoint_digest.present?
        raise RestoreError, "This backup predates deliberate memory erasure; automatic resurrection is forbidden"
      end
      raise RestoreError, "Memory erasure is pending" if agent.memory_vault&.erasure_requested_at?
      Agents::RotateCredentials.owner(agent) # Fail before destructive work.
      Backup::AgentRestic.verify_archive!(agent)

      graph = snapshot.graph_checkpoint_digest.present? ? Backup::GraphCheckpoint.read(agent, snapshot) : nil
      if agent.memory_vault && !graph
        raise RestoreError, "Backup has no paired graph checkpoint; refusing to wake with mismatched memory"
      end
      vault = if graph
        agent.memory_vault || agent.create_memory_vault!
      end
      was_suspended = vault&.suspended_at
      vault&.update!(suspended_at: Time.current)
      if graph
        # Validate the complete graph in a rollback-only savepoint before any
        # container or identity volume is removed.
        Mnemodyne::Vault.transaction(requires_new: true) do
          Mnemodyne::Checkpoint.import(vault, graph, replace: true)
          raise ActiveRecord::Rollback
        end
        vault.reload
      end

      puts "Restoring Chaos agent #{agent.name} (#{agent.uuid}) from #{snapshot.restic_snapshot_id}..."
      remove_container!
      recreate_volumes!
      restore_snapshot!(snapshot.restic_snapshot_id)
      if graph
        Mnemodyne::Checkpoint.import(vault, graph, replace: true)
      end
      configure_for_local_runtime!
      Agents::RotateCredentials.call(agent)
      vault&.update!(suspended_at: was_suspended)
      Agents::Sandbox.new(agent).spawn! if wake && agent.external? && !was_suspended
      puts "Restored Chaos agent #{agent.name}."
    end

    private

    attr_reader :agent

    def remove_container!
      return if agent.container_name.blank?

      result = docker_capture("rm", "-f", agent.container_name)
      return if result[:ok] || result[:stderr].include?("No such container")

      raise RestoreError, docker_error("remove container #{agent.container_name}", result)
    end

    def recreate_volumes!
      Agents::VolumeSet.new(agent).each do |_name, volume|
        removal = docker_capture("volume", "rm", "-f", volume)
        unless removal[:ok] || removal[:stderr].include?("No such volume")
          raise RestoreError, docker_error("remove Docker volume #{volume}", removal)
        end

        creation = docker_capture("volume", "create", *Agents::Resources.new(agent).labels, volume)
        raise RestoreError, docker_error("create Docker volume #{volume}", creation) unless creation[:ok]
      end
    end

    def restore_snapshot!(snapshot_id)
      command = [
        "docker", "run", "--rm",
        *Backup::AgentRestic.restore_mounts(agent),
        *Backup::AgentRestic.docker_environment(agent),
        Backup::AgentRestic::IMAGE,
        "restore", snapshot_id,
        "--target", "/restore"
      ]
      success = system(*command)
      raise RestoreError, "Restic restore failed for #{agent.name}" unless success
    end

    def docker_capture(*args)
      stdout, stderr, status = Open3.capture3("docker", *args)
      { stdout: stdout, stderr: stderr, ok: status.success? }
    end

    def docker_error(action, result)
      detail = result[:stderr].presence || result[:stdout].presence || "unknown Docker error"
      "Could not #{action}: #{detail.strip}"
    end

    def configure_for_local_runtime!
      agent.update!(
        container_image: Agents::Config.default_image,
        sandbox_host: Agents::Config.sandbox_host,
        endpoint_url: nil,
        health_state: "unknown",
        consecutive_health_failures: 0,
        sandbox_last_error: nil,
        sandbox_last_error_at: nil
      )
    end

  end
end
