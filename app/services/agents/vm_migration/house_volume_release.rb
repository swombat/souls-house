module Agents
  class VmMigration
    # Removes the house volumes a recovered rollback left behind (#426).
    #
    # This is the first code in the house that deletes any part of a
    # resident's home, so it is narrow on purpose:
    #
    # - It runs only when asked (release!), never on a schedule. Whether the
    #   house should ever do this by itself is Daniel's call (jaMMNj).
    # - It is admitted only for a rollback that is recovered with its
    #   recovery bound to its swap receipt (RollbackRelease.unadmitted_reason),
    #   whose resident is still on that swap's map, at that reservation, with
    #   no other attempt open and its placement the house's, and only once
    #   HOLD has passed since the recovery was verified.
    # - What it may remove is a closed list computed from the records, never
    #   from what Docker happens to hold: the map the swap replaced (from its
    #   receipt), and the rollback volumes of this resident's earlier,
    #   spent generations. Every name must be this resident's own name for
    #   its role (Resources#derived_volumes, or that plus "-rb<generation>"
    #   below this attempt's), and none may be on the map it runs on now.
    # - Before each removal Docker is asked: a rollback volume must carry this
    #   resident's rollback label for its generation, a namespaced instance's
    #   volume this checkout's label, and no container may use it. Docker's
    #   own `volume rm` (without -f) refuses a volume in use as well.
    # - Each removal is an audit row; a name already gone is reported, not
    #   an error, so asking twice is safe.
    class HouseVolumeRelease

      class Refused < StandardError; end

      HOLD = 7.days
      ROLES = Agents::Resources::ROLES
      ROLLBACK_LABEL = RollbackPlan::LABEL
      CHECKOUT_LABEL = "house.souls.checkout".freeze

      Candidate = Data.define(:role, :name, :source, :generation)
      Outcome = Data.define(:name, :status, :detail)

      DOCKER = ->(*argv) { Agents::BoundedCommand.capture3(*argv, deadline: Agents::BoundedCommand.now + 30) }

      # Why this rollback's leftovers may not be removed now, or nil.
      def self.unadmitted_reason(rollback, now: Time.current)
        refusal = RollbackRelease.unadmitted_reason(rollback)
        return refusal if refusal

        agent = Agent.find(rollback.agent_id)
        return "The resident is no longer on this rollback's volumes" unless agent.volume_map == rollback.volume_map.to_h
        unless agent.volume_rollback_generation.to_i == rollback.generation
          return "A newer rollback has been reserved for this resident"
        end
        return "Another rollback of this resident is still open" if VmRollback.open.where(agent_id: agent.id).exists?

        placement = AgentPlacement.find(rollback.agent_placement_id)
        unless placement.backend == "local" && placement.state == "ready" &&
            placement.generation == rollback.source["placement_generation"].to_i + 1
          return "The resident's placement is not the one this rollback made the house's"
        end

        verified_at = begin
          Time.iso8601(rollback.recovery.to_h["verified_at"].to_s)
        rescue ArgumentError
          nil
        end
        return "The recovery has no verified time" unless verified_at
        if verified_at > now - HOLD
          return "The old volumes are kept until #{(verified_at + HOLD).utc.iso8601}, #{HOLD.inspect} after the recovery"
        end

        nil
      end

      def initialize(rollback, docker: DOCKER, instance: LocalInstance.current, now: -> { Time.current })
        @rollback = rollback
        @docker = docker
        @instance = instance
        @now = now
      end

      # The closed list, from the records alone. Raises Refused if a recorded
      # name is not this resident's own, rather than skipping it quietly.
      def candidates
        agent = Agent.find(@rollback.agent_id)
        resources = Agents::Resources.new(agent, instance: @instance)
        derived = resources.derived_volumes.transform_keys(&:to_s)
        live = @rollback.volume_map.to_h.values

        swap = AuditLog.where(action: "vm_rollback_swap", auditable_type: "Agent", auditable_id: agent.id)
          .where("data->>'generation' = ?", @rollback.generation.to_s).order(:id).first
        raise Refused, "The swap receipt for this rollback is missing" unless swap

        previous = swap.data["previous_map"] || derived
        list = ROLES.map(&:to_s).map do |role|
          name = previous.fetch(role) { raise Refused, "The swap receipt names no #{role} volume" }
          Candidate.new(role:, name:, source: "replaced_map", generation: generation_of(name, derived.fetch(role)))
        end
        (1...@rollback.generation).each do |generation|
          ROLES.map(&:to_s).each do |role|
            list << Candidate.new(role:, name: "#{derived.fetch(role)}-rb#{generation}", source: "spent_generation", generation:)
          end
        end

        list = list.uniq(&:name).reject { |candidate| live.include?(candidate.name) }
        list.each { |candidate| check_own!(candidate, derived) }
        list
      end

      # Removes the closed list, under the resident's row lock so the
      # admission cannot change underneath. Returns one Outcome per name.
      def release!(by:)
        agent = Agent.find(@rollback.agent_id)
        agent.with_lock do
          @rollback.reload
          refusal = self.class.unadmitted_reason(@rollback, now: @now.call)
          raise Refused, refusal if refusal

          candidates.map { |candidate| remove(candidate, agent:, by:) }
        end
      end

      private

      def generation_of(name, base)
        return nil if name == base

        suffix = name.delete_prefix(base)
        suffix.match?(Agents::Resources::ROLLBACK_SUFFIX) ? suffix.delete_prefix("-rb").to_i : nil
      end

      def check_own!(candidate, derived)
        base = derived.fetch(candidate.role)
        own = candidate.name == base ||
          (candidate.generation && candidate.generation < @rollback.generation && candidate.name == "#{base}-rb#{candidate.generation}")
        raise Refused, "#{candidate.name} is not this resident's #{candidate.role} volume" unless own
      end

      def remove(candidate, agent:, by:)
        out, err, status = @docker.call("docker", "volume", "inspect", "--format",
          "{{ index .Labels \"#{ROLLBACK_LABEL}\" }}|{{ index .Labels \"#{CHECKOUT_LABEL}\" }}", candidate.name)
        unless status.success?
          return Outcome.new(name: candidate.name, status: :absent, detail: nil) if err.to_s.match?(/no such volume/i)

          return Outcome.new(name: candidate.name, status: :unknown, detail: "Could not inspect the volume")
        end

        rollback_label, checkout_label = out.to_s.strip.split("|", 2).map(&:to_s)
        if candidate.generation && !rollback_label.start_with?("#{agent.uuid}/#{candidate.generation}/")
          return Outcome.new(name: candidate.name, status: :foreign, detail: "Not labelled as this resident's rollback #{candidate.generation}")
        end
        if @instance.namespace && checkout_label != @instance.fingerprint
          return Outcome.new(name: candidate.name, status: :foreign, detail: "Not labelled as this checkout's")
        end

        users, _err, status = @docker.call("docker", "ps", "-a", "-q", "--filter", "volume=#{candidate.name}")
        return Outcome.new(name: candidate.name, status: :unknown, detail: "Could not list its containers") unless status.success?
        return Outcome.new(name: candidate.name, status: :in_use, detail: "A container still uses it") if users.to_s.strip.present?

        _out, err, status = @docker.call("docker", "volume", "rm", candidate.name)
        return Outcome.new(name: candidate.name, status: :refused, detail: err.to_s.strip.first(200)) unless status.success?

        AuditLog.create!(action: "house_volume_released", user: by, account: agent.account, auditable: agent,
          data: { "rollback_id" => @rollback.id, "generation" => @rollback.generation, "volume" => candidate.name,
                  "role" => candidate.role, "source" => candidate.source, "volume_generation" => candidate.generation })
        Outcome.new(name: candidate.name, status: :removed, detail: nil)
      end

    end
  end
end
