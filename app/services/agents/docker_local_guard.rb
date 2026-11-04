module Agents
  module DockerLocalGuard

    module_function

    def check!(deadline: nil)
      return unless LocalInstance.current.local?
      host = ENV["DOCKER_HOST"]
      if host.blank? || ENV["DOCKER_CONTEXT"].present?
        stdout, _stderr, status = BoundedCommand.capture3("docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}", deadline:)
        raise Resources::OwnershipError, "Cannot determine local Docker endpoint" unless status.success?
        host = stdout.strip
      end
      unless host.start_with?("unix://")
        raise Resources::OwnershipError, "Local instances require a Unix-socket Docker endpoint; refusing remote Docker"
      end
    end

  end
end
