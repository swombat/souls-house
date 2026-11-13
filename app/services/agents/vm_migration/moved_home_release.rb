module Agents
  class VmMigration
    # Removes the house home of a resident whose move to its own server has
    # finished (#426). The same per-volume machinery as HouseVolumeRelease
    # (local-endpoint guard, closed list, label and in-use checks, an
    # attributed intent committed before each `docker volume rm`, receipts
    # that survive a crash, top level only), on a different basis:
    #
    # - The move finished: the placement is a migration, ready, at the
    #   generation this release was asked for, with its vm_migration_ready
    #   receipt, and the resident has its runtime_ready_at.
    # - The server has its own copy: a VmBackup taken on that placement and
    #   generation, issued after the move was ready, is verified. Until then
    #   the house home (with the carry) is the only home it lived in that is
    #   known to be whole. A rollback restores from the server's repository,
    #   never from the house home (RollbackPlan), so the home is not needed
    #   to come back once that backup exists.
    # - HOLD has passed since the move was ready.
    # - No rollback is open, and none has been reserved since the release
    #   was asked for (volume_rollback_generation unchanged), so a fresh
    #   rollback's volumes are never on the list.
    #
    # The list: the resident's derived names, the map it last ran on at the
    # house (after an earlier rollback, its -rb set), and the -rb volumes of
    # every generation reserved before the release was asked for. All must be
    # this resident's own names for their roles. Nothing on it is live: the
    # resident runs on its server. Operator-only, like the rollback release.
    class MovedHomeRelease < HouseVolumeRelease

      READY = "vm_migration_ready".freeze

      # Why this resident's house home may not be removed now, or nil.
      # generation: the placement generation the move was made ready at;
      # spent: the resident's volume_rollback_generation when asked.
      def self.unadmitted_reason(agent, generation:, spent:, now: Time.current)
        placement = AgentPlacement.uncached { AgentPlacement.find_by(agent_id: agent.id) }
        unless placement&.migration? && placement.state == "ready" && placement.generation == generation
          return "The resident is not on the server this move made ready"
        end
        return "The resident's move has not finished" if agent.runtime_ready_at.nil?
        return "A rollback of this resident is open" if VmRollback.open.where(agent_id: agent.id).exists?
        unless agent.volume_rollback_generation.to_i == spent
          return "A rollback has been reserved for this resident since the release was asked for"
        end

        ready = AuditLog.where(action: READY, auditable_type: "Agent", auditable_id: agent.id)
          .where("data->>'placement_id' = ? AND data->>'generation' = ?", placement.id.to_s, generation.to_s)
          .order(:id).first
        return "The move has no ready receipt" unless ready

        backed_up = VmBackup.where(agent_id: agent.id, state: "verified").joins(:runner_command)
          .where(runner_commands: { agent_placement_id: placement.id, generation: })
          .where("runner_commands.created_at > ?", ready.created_at).exists?
        return "No backup taken on its server since the move has been verified" unless backed_up
        if ready.created_at > now - HOLD
          return "The house home is kept until #{(ready.created_at + HOLD).utc.iso8601}, #{HOLD.inspect} after the move"
        end

        nil
      end

      # placement: the resident's migration placement, as the operator saw it.
      def initialize(placement, docker: DOCKER, guard: GUARD, instance: LocalInstance.current, now: -> { Time.current })
        @placement_id = placement.id
        @generation = placement.generation
        @agent_id = placement.agent_id
        @spent = Agent.find(@agent_id).volume_rollback_generation.to_i
        @docker = docker
        @guard = guard
        @instance = instance
        @now = now
      end

      def candidates
        agent = Agent.find(@agent_id)
        derived = Agents::Resources.new(agent, instance: @instance).derived_volumes.transform_keys(&:to_s)

        list = ROLES.map(&:to_s).map do |role|
          Candidate.new(role:, name: derived.fetch(role), source: "house_home", generation: nil)
        end
        agent.volume_map.to_h.each do |role, name|
          base = derived.fetch(role.to_s) { raise Refused, "The resident's map names an unknown role #{role}" }
          list << Candidate.new(role: role.to_s, name: name.to_s, source: "house_map", generation: generation_of(name.to_s, base))
        end
        (1..@spent).each do |generation|
          ROLES.map(&:to_s).each do |role|
            list << Candidate.new(role:, name: "#{derived.fetch(role)}-rb#{generation}", source: "spent_generation", generation:)
          end
        end

        list = list.uniq(&:name)
        list.each { |candidate| check_own!(candidate, derived) }
        list
      end

      protected

      def current_refusal
        self.class.unadmitted_reason(Agent.find(@agent_id), generation: @generation, spent: @spent, now: @now.call)
      end

      def subject_data
        { "basis" => "move", "placement_id" => @placement_id, "placement_generation" => @generation }
      end

      def spent_generation?(generation)
        generation.between?(1, @spent)
      end

    end
  end
end
