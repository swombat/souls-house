module Backup
  # Explicit synthetic-only local transport. Never reads cloud configuration,
  # accepts a repository path, or adopts a volume from another checkout.
  class LocalRepository

    def self.enabled?
      ENV["MNEMODYNE_LOCAL_BACKUP"] == "1"
    end

    def initialize(agent)
      @agent = agent
      @resources = Agents::Resources.new(agent)
      unless LocalInstance.current.namespace && LocalInstance.current.environment == "test" &&
          agent.uuid.present? && ENV["MNEMODYNE_LOCAL_BACKUP_AGENT_UUID"] == agent.uuid
        raise ArgumentError, "Local backup requires an isolated synthetic Mnemodyne resident"
      end
      @resources.verify_existing!
    end

    def volume
      "#{@resources.container}-backups"
    end

    def environment
      output, error, status = Open3.capture3("docker", "volume", "inspect", "--format",
        '{{ index .Labels "house.souls.checkout" }}', volume)
      if status.success?
        raise Agents::Resources::OwnershipError, "Foreign backup volume" unless output.strip == LocalInstance.current.fingerprint
      elsif error.match?(/No such volume/i)
        _, _, created = Open3.capture3("docker", "volume", "create", *@resources.labels, volume)
        raise ArgumentError, "Could not create isolated backup volume" unless created.success?
      else
        raise ArgumentError, "Could not inspect isolated backup volume"
      end
      [ "-v", "#{volume}:/repository", "-e", "RESTIC_REPOSITORY=/repository",
        "-e", "RESTIC_PASSWORD=#{@agent.restic_password}" ]
    end

  end
end
