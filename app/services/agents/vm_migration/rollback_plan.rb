module Agents
  class VmMigration
    # Checkpoint 3 of #426 3C: bringing a moved resident back to the house.
    #
    # What it protects: the house home the resident lived in before the move.
    # A rollback never writes into a live volume. Every one of the five
    # volumes (identity, chaos, repo, work, state) is restored from the
    # resident's own repository into a FRESH volume named for this rollback;
    # only when all five are restored and verified is the resident's
    # container pointed at them (the swap). The old volumes stay untouched
    # until a later, separate release, so a rollback that fails at any step
    # leaves the house exactly as it was.
    #
    # This class only plans: it names targets and refuses unsafe ones. It does
    # no Docker IO and holds no lock.
    class RollbackPlan
      class Unsafe < StandardError; end

      ROLES = %i[identity chaos repo work state].freeze

      Target = Data.define(:role, :live, :fresh)

      def initialize(agent, generation:, resources: Resources.new(agent))
        raise ArgumentError, "generation must be a positive integer" unless generation.is_a?(Integer) && generation.positive?

        @agent = agent
        @generation = generation
        @resources = resources
      end

      attr_reader :generation

      # One target per role, in ROLES order. Raises Unsafe if any fresh name
      # would be a live name (of any role), or if the live map is not exactly
      # the five roles this plan covers.
      def targets
        live = @resources.volumes
        unless live.keys.sort == ROLES.sort
          raise Unsafe, "Rollback covers #{ROLES.join(', ')}; resources name #{live.keys.sort.join(', ')}"
        end

        planned = ROLES.map { |role| Target.new(role:, live: live.fetch(role), fresh: "#{live.fetch(role)}-rb#{generation}") }
        clash = planned.map(&:fresh) & live.values
        raise Unsafe, "Refusing to restore into a live volume: #{clash.join(', ')}" if clash.any?

        planned
      end

      # Refuses a plan whose fresh volumes already exist: a leftover from an
      # earlier attempt of the same generation is never reused or overwritten.
      # exists: ->(name) -> boolean (a Docker volume inspect, injected).
      def check_fresh_absent!(exists:)
        present = targets.map(&:fresh).select { |name| exists.call(name) }
        raise Unsafe, "Rollback volumes already exist: #{present.join(', ')}" if present.any?

        true
      end
    end
  end
end
