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

    # The container's Linux hostname. Docker's default is the container id,
    # which changes on every recreate. This is derived from the agent UUID, so
    # it is stable across recreates and distinct per resident, and the prefix
    # keeps it distinct from any personal machine a resident also runs on.
    # It says where a process ran, never which run or session it was.
    def hostname
      name = "souls-house-#{uuid.downcase}"
      unless name.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/)
        raise ArgumentError, "Agent UUID does not give a valid hostname"
      end
      name
    end

    ROLES = %i[identity chaos repo work state].freeze
    ROLLBACK_SUFFIX = /\A-rb[1-9][0-9]{0,8}\z/

    # The five volumes the resident runs on. When the agent carries a
    # volume_map (set by a rollback swap, #426 3C checkpoint 3) that map is
    # the answer, and it must be complete and this resident's own: exactly the
    # five roles, distinct names, each either the derived name for its role or
    # that name plus a rollback suffix (so the namespace and the agent UUID
    # bound it). Anything else raises: there is no partial fallback, because
    # a container started on a mix of old and new volumes is the failure the
    # map exists to prevent.
    def volumes
      map = agent.respond_to?(:volume_map) ? agent.volume_map : nil
      return derived_volumes if map.nil?

      validated_map(map)
    end

    # The names derived from the instance and the agent UUID alone: what every
    # resident without a volume_map runs on, and the base a rollback's fresh
    # names are built from.
    def derived_volumes
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
      begin
        RuntimeLocation.require_local!(agent)
      rescue RuntimeLocation::Unavailable => error
        raise OwnershipError, error.message
      end
      return unless instance.namespace
      if agent.container_name.present? && agent.container_name != container
        raise OwnershipError, "Stored container does not belong to this local instance; refusing Docker access"
      end
    end

    # Called immediately before real Docker IO (not merely when constructing a
    # service). Verify existing resources, but permit absent ones to be created.
    # deadline (a BoundedCommand clock reading) bounds every inspect; past it
    # BoundedCommand::TimedOut is raised and the inspect is killed.
    def verify_existing!(deadline: nil)
      validate!
      DockerLocalGuard.check!(deadline:)
      return unless instance.namespace
      ([ [ :container, container ] ] + volumes.values.map { |name| [ :volume, name ] }).each do |kind, name|
        format = kind == :container ? '{{ index .Config.Labels "house.souls.checkout" }}' : '{{ index .Labels "house.souls.checkout" }}'
        stdout, stderr, status = BoundedCommand.capture3("docker", kind.to_s, "inspect", "--format", format, name, deadline:)
        if status.success?
          raise OwnershipError, "Docker #{kind} #{name} has foreign or missing ownership labels" unless stdout.strip == instance.fingerprint
        elsif !stderr.match?(/No such (?:object|container|volume)/i)
          raise OwnershipError, "Cannot verify Docker #{kind} ownership"
        end
      end
    end

    private

    def validated_map(map)
      raise OwnershipError, "Volume map is not a map" unless map.is_a?(Hash)

      roles = map.keys.map(&:to_s)
      unless roles.sort == ROLES.map(&:to_s).sort
        raise OwnershipError, "Volume map must name exactly #{ROLES.join(', ')}"
      end

      derived = derived_volumes
      result = ROLES.to_h do |role|
        name = map[role.to_s] || map[role]
        raise OwnershipError, "Volume map has a blank name for #{role}" unless name.is_a?(String) && name.present?

        base = derived.fetch(role)
        unless name == base || (name.start_with?(base) && ROLLBACK_SUFFIX.match?(name.delete_prefix(base)))
          raise OwnershipError, "Volume map names a volume that is not this resident's #{role} volume"
        end
        [ role, name ]
      end
      # Distinct names follow from the line above: each name is bound to its
      # own role's derived name, and no two roles share one (a mutation that
      # removed an explicit uniqueness check here left every test green).
      result
    end

    def uuid
      value = agent.uuid.to_s
      raise OwnershipError, "Invalid agent UUID for Docker resource" unless value.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/)
      value
    end

  end
end
