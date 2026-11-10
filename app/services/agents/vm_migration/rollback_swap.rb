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
      # evidence: what proved the fresh volumes (the snapshot id and the
      #   per-role shapes), kept in the receipt with the previous map.
      def initialize(agent, plan:, verified:, in_commit: ->(_agent) {}, start: ->(_agent) {}, evidence: {})
        @agent = agent
        @plan = plan
        @verified = verified
        @in_commit = in_commit
        @start = start
        @evidence = evidence
      end

      def call
        previous = @plan.source_map
        fresh = @plan.fresh_map
        if Agent.connection.transaction_open?
          # Inside any enclosing transaction, joinable or not, our "commit"
          # would only be a savepoint: the receipt is visible to this
          # connection but not durable, and start would run before the swap
          # was. So the swap runs only at the top level.
          return failed(:before_commit, previous, fresh, "The swap must not run inside an open transaction")
        end
        missing = RollbackPlan::ROLES.reject { |role| @verified[role] == true || @verified[role.to_s] == true }
        return failed(:before_commit, previous, fresh, "Not verified: #{missing.join(', ')}") if missing.any?

        # Every outcome is judged by this call's own receipt, found by a token
        # only this call knows, read back outside any transaction. An older
        # receipt for the same generation proves nothing about this call.
        token = SecureRandom.hex(16)
        begin
          commit!(previous, fresh, token)
        rescue StandardError => error
          # An error raised by a callback after the database commit (an
          # after_commit hook, say) still comes out of with_lock. The receipt
          # tells the two apart: if it is there, the swap committed, and this
          # is an after_commit failure. start is not run: what committed
          # alongside the error is for a person to look at.
          return failed(:after_commit, previous, fresh, "Committed, then: #{error.message}") if committed?(token, fresh)

          return failed(:before_commit, previous, fresh, error.message)
        end
        # A swallowed ActiveRecord::Rollback leaves commit! returning normally
        # with nothing written, and must not reach start.
        unless committed?(token, fresh)
          return failed(:before_commit, previous, fresh, "The swap did not commit")
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

      def commit!(previous, fresh, token)
        @agent.with_lock do
          # with_lock reloads the row, so this compares the database against the
          # plan's source map, not against whatever this object last held.
          raise Failed, "The resident's volume map is not the one this rollback was planned from" unless @agent.volume_map == previous
          # The reservation is rechecked HERE, under the same lock as the
          # commit (Mira, #838 review 6758830079): a newer reservation made
          # during a long restore leaves the map unchanged, so only the
          # generation shows that this attempt has been superseded.
          unless @agent.volume_rollback_generation.to_i == @plan.generation
            raise Failed, "Rollback generation #{@plan.generation} is no longer this resident's latest reservation"
          end
          # A generation is consumed by its first committed swap. Retrying a
          # plan (for instance after a revert! restored its source map) must
          # take a fresh reservation, not reuse a spent one.
          raise Failed, "Rollback generation #{@plan.generation} has already been swapped" if receipts.exists?

          @agent.update!(volume_map: fresh)
          @in_commit.call(@agent)
          AuditLog.create!(user: nil, account: @agent.account, action: "vm_rollback_swap", auditable: @agent,
            data: { by: "house", generation: @plan.generation, token:, previous_map: previous, volume_map: fresh,
                    evidence: @evidence })
        end
      end

      def receipts
        AuditLog.where(action: "vm_rollback_swap", auditable: @agent)
          .where("data->>'generation' = ?", @plan.generation.to_s)
      end

      # The receipt is written in the same transaction as the map, so this
      # call's receipt row exists exactly when this call's swap committed.
      def committed?(token, fresh)
        receipts.where("data->>'token' = ?", token).any? { |receipt| receipt.data["volume_map"] == fresh }
      end

      def failed(phase, previous, fresh, message)
        Outcome.new(status: :failed, phase:, previous_map: previous, fresh_map: fresh, error: message)
      end
    end
  end
end
