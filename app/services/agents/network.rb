module Agents
  class Network

    def self.ensure!
      Agents::DockerLocalGuard.check!
      network = Agents::Config.network
      instance = LocalInstance.current
      stdout, stderr, status = Open3.capture3("docker", "network", "inspect", "--format", '{{ index .Labels "house.souls.checkout" }}', network)
      if status.success?
        if instance.namespace && stdout.strip != instance.fingerprint
          raise Resources::OwnershipError, "Agent network has foreign or missing ownership labels"
        end
        return true
      end
      raise Resources::OwnershipError, "Cannot verify agent network" unless stderr.match?(/No such network|network .* not found/i)
      labels = instance.namespace ? [ "--label", "house.souls.checkout=#{instance.fingerprint}", "--label", "house.souls.instance=#{instance.namespace}" ] : []
      system("docker", "network", "create", *labels, network) || raise("failed to create docker network #{network}")
    end

  end
end
