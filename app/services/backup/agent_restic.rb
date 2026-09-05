module Backup
  module AgentRestic

    module_function

    def docker_environment(agent)
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
