module Agents
  class VmMigration
    # The swap at the end of a rollback (#426 3C checkpoint 3): the one commit
    # that points the resident at its five freshly restored volumes.
    #
    # There are exactly two kinds of failure, and they are told apart by
    # whether that commit happened:
    #
    # before_commit: something short of the commit failed (a role not
    #   verified, the agent's map changed under us, the commit itself rolled
    #   back). Nothing about the resident changed: it still runs on its live
    #   volumes and its placement is as it was. The fresh volumes are leftovers
    #   for a separate release; they are never reused (the generation is spent).
    #
    # after_commit: the map (and whatever in_commit changed, i.e. the
    #   placement) is committed, and the step after it, starting the resident
    #   on the new volumes, failed. The house is now in the new state; the
    #   receipt holds the previous map, and the old volumes are still there,
    #   untouched, so revert! can point the resident back. Nothing is reverted
    #   silently: which way to go after a failed start is a decision.
    #
    # The receipt is an AuditLog row (vm_rollback_swap) written in the same
    # transaction as the map, so there is never a committed map without its
    # previous map recorded.
    class RollbackSwap
      class Failed < StandardError; end

      Outcome = Data.define(:status, :phase, :previous_map, :fresh_map, :error) do
        def ok? = status == :ok
      end

      # verified: role => true for each role whose fresh volume passed
      #   restic restore --verify and its shape digest.
      # in_commit: called inside the commit's transaction (the placement
      #   switch); raising there rolls the whole commit back (before_commit).
      # start: called after the commit (recreate the container on the map).
      def initialize(agent, plan:, verified:, in_commit: ->(_agent) {}, start: ->(_agent) {})
        @agent = agent
        @plan = plan
        @verified = verified
        @in_commit = in_commit
        @start = start
      end

      def call
        previous = @agent.volume_map
        fresh = @plan.fresh_map
        missing = RollbackPlan::ROLES.reject { |role| @verified[role] == true || @verified[role.to_s] == true }
        return failed(:before_commit, previous, fresh, "Not verified: #{missing.join(', ')}") if missing.any?

        begin
          commit!(previous, fresh)
        rescue StandardError => error
          return failed(:before_commit, previous, fresh, error.message)
        end

        begin
          @start.call(@agent)
        rescue StandardError => error
          return failed(:after_commit, previous, fresh, error.message)
        end

        Outcome.new(status: :ok, phase: :started, previous_map: previous, fresh_map: fresh, error: nil)
      end

      # Points the resident back at the map it ran on before this swap, only if
      # it is still on this swap's map. Audited like the swap.
      def self.revert!(agent, previous_map:, fresh_map:)
        agent.with_lock do
          raise Failed, "The resident is no longer on this rollback's volumes; not reverting" unless agent.volume_map == fresh_map

          agent.update!(volume_map: previous_map)
          AuditLog.create!(user: nil, account: agent.account, action: "vm_rollback_revert", auditable: agent,
            data: { by: "house", previous_map: fresh_map, volume_map: previous_map })
        end
      end

      private

      def commit!(previous, fresh)
        @agent.with_lock do
          raise Failed, "The resident's volume map changed during the rollback" unless @agent.volume_map == previous

          @agent.update!(volume_map: fresh)
          @in_commit.call(@agent)
          AuditLog.create!(user: nil, account: @agent.account, action: "vm_rollback_swap", auditable: @agent,
            data: { by: "house", generation: @plan.generation, previous_map: previous, volume_map: fresh })
        end
      end

      def failed(phase, previous, fresh, message)
        Outcome.new(status: :failed, phase:, previous_map: previous, fresh_map: fresh, error: message)
      end
    end
  end
end
