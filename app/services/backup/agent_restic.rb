module Backup
  module AgentRestic

    IMAGE = "restic/restic:0.18.1"

    class ResidentBusy < ArgumentError; end

    module_function

    def docker_environment(agent)
      return LocalRepository.new(agent).environment if LocalRepository.enabled?
      if LocalInstance.current.namespace
        raise ArgumentError, "Remote agent backups/restores are disabled for isolated local instances"
      end
      Agents::DockerLocalGuard.check!
      [
        "-e", "AWS_ACCESS_KEY_ID=#{aws_value(:access_key_id)}",
        "-e", "AWS_SECRET_ACCESS_KEY=#{aws_value(:secret_access_key)}",
        "-e", "AWS_DEFAULT_REGION=#{region}",
        "-e", "RESTIC_PASSWORD=#{agent.restic_password}",
        "-e", "RESTIC_REPOSITORY=#{repository_url(agent)}"
      ]
    end

    def verify_archive!(agent)
      _, _, status = Open3.capture3("docker", "run", "--rm", *docker_environment(agent),
        IMAGE, "check", "--read-data")
      raise ArgumentError, "Backup archive integrity verification failed" unless status.success?
    end

    def with_quiesced(agent)
      vault = agent.memory_vault
      return yield unless vault
      Agents::Resources.new(agent).verify_existing!
      vault.with_lock do
        raise ArgumentError, "Erasure is pending" if vault.erasure_requested_at?
        raise ResidentBusy, "Backup requires an idle resident" if agent.agent_runtime_interactions.active.exists?
        output, _, status = Open3.capture3("docker", "inspect", "--format", "{{.State.Running}} {{.State.Paused}}", agent.container_name)
        paused_here = false
        begin
          if status.success? && output.strip == "true false"
            _, _, paused = Open3.capture3("docker", "pause", agent.container_name)
            raise ArgumentError, "Could not quiesce resident filesystem" unless paused.success?
            paused_here = true
          elsif status.success? && !%w[false].include?(output.split.first) && output.strip != "true true"
            raise ArgumentError, "Cannot establish resident filesystem state"
          elsif !status.success?
            # Offline residents can have volumes but no container. Distinguish
            # absence from daemon errors through the ownership verifier above.
            raise ArgumentError, "Missing hosted runtime" if agent.external?
          end
          raise ResidentBusy, "Resident became active before checkpoint" if agent.agent_runtime_interactions.active.exists?
          yield
        ensure
          if paused_here
            original_error = $!
            begin
              _, _, resumed = Open3.capture3("docker", "unpause", agent.container_name)
              raise ArgumentError, "Resident remains paused after backup" unless resumed.success?
            rescue StandardError
              Rails.logger.error("Resident remains paused after backup")
              raise unless original_error
            end
          end
        end
      end
    end

    def repository_url(agent)
      "s3:s3.amazonaws.com/#{bucket}/agents/#{agent.uuid}"
    end

    def backup_mounts(agent)
      backed_up_volumes(agent).flat_map do |name, volume|
        [ "-v", "#{volume}:/data/#{name}:ro" ]
      end
    end

    def restore_mounts(agent)
      backed_up_volumes(agent).flat_map do |name, volume|
        [ "-v", "#{volume}:/restore/data/#{name}" ]
      end
    end

    def backed_up_volumes(agent)
      Agents::VolumeSet.new(agent).names.except(:state)
    end

    def bucket
      ENV["RESTIC_S3_BUCKET"].presence ||
        aws_credentials[:agent_backups_bucket].presence ||
        aws_credentials[:postgres_bucket].presence ||
        raise(ArgumentError, "aws.agent_backups_bucket or aws.postgres_bucket must be configured")
    end

    def region
      return ENV["AWS_REGION"] if ENV["AWS_REGION"].present?

      if aws_credentials[:agent_backups_bucket].present?
        aws_credentials[:agent_backups_bucket_region].presence ||
          aws_credentials[:s3_region].presence ||
          "eu-west-1"
      else
        aws_credentials[:postgres_bucket_region].presence ||
          aws_credentials[:s3_region].presence ||
          "eu-west-1"
      end
    end

    def aws_value(name)
      env_name = {
        access_key_id: "AWS_ACCESS_KEY_ID",
        secret_access_key: "AWS_SECRET_ACCESS_KEY"
      }.fetch(name)

      ENV[env_name].presence || aws_credentials[name].presence ||
        raise(ArgumentError, "#{env_name} or aws.#{name} must be configured")
    end

    def aws_credentials
      Rails.application.credentials.aws || {}
    end

  end
end
