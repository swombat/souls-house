module Agents
  # One source for names, including the legacy names retained by production and
  # primary development. A stored container name is never an authority to act.
  class Resources

    class OwnershipError < StandardError; end

    attr_reader :agent, :instance

    def initialize(agent, instance: LocalInstance.current)
      @agent = agent
      @instance = instance
    end

    def container
      prefix = instance.namespace || "hk"
      "#{prefix}-agent-#{uuid}"
    end

    def volumes
      {
        identity: "#{container}-identity",
        chaos: instance.namespace ? "#{container}-chaos" : "chaos-home-#{uuid}",
        repo: "#{container}-repo", work: "#{container}-work", state: "#{container}-state"
      }
    end

    def labels
      return [] unless instance.namespace
      [ "--label", "house.souls.instance=#{instance.namespace}",
       "--label", "house.souls.checkout=#{instance.fingerprint}" ]
    end

    def validate!
      return unless instance.namespace
      if agent.container_name.present? && agent.container_name != container
        raise OwnershipError, "Stored container does not belong to this local instance; refusing Docker access"
      end
    end

    # Called immediately before real Docker IO (not merely when constructing a
    # service). Verify existing resources, but permit absent ones to be created.
    def verify_existing!
      validate!
      DockerLocalGuard.check!
      return unless instance.namespace
      ([ [ :container, container ] ] + volumes.values.map { |name| [ :volume, name ] }).each do |kind, name|
        format = kind == :container ? '{{ index .Config.Labels "house.souls.checkout" }}' : '{{ index .Labels "house.souls.checkout" }}'
        stdout, stderr, status = Open3.capture3("docker", kind.to_s, "inspect", "--format", format, name)
        if status.success?
          raise OwnershipError, "Docker #{kind} #{name} has foreign or missing ownership labels" unless stdout.strip == instance.fingerprint
        elsif !stderr.match?(/No such (?:object|container|volume)/i)
          raise OwnershipError, "Cannot verify Docker #{kind} ownership"
        end
      end
    end

    private

    def uuid
      value = agent.uuid.to_s
      raise OwnershipError, "Invalid agent UUID for Docker resource" unless value.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/)
      value
    end

  end
end
