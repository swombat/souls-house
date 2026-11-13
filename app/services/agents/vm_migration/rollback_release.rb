module Agents
  class VmMigration
    # Releases the server a rollback brought its resident back from (#426
    # release_vm!). The rollback's switch made the placement the house's and
    # kept the server, stopped and fenced, in case the move back needed it.
    # This deletes that server, and only that one:
    #
    # - It targets the purchases the attempt recorded before the switch
    #   (VmRollback#source_operations), never whatever the placement holds
    #   by then, and it never touches the placement: VmCleanupJob would
    #   retire it and take the resident off the house.
    # - It deletes only for a recovered attempt whose recovery receipt is
    #   bound to the swap receipt in the audit log (same token, generation
    #   and map). A committed attempt whose recreate failed keeps its server
    #   (Mira, jaMMNj eMaBpK), even when the release was asked for.
    # - Once the provider confirms every purchase is gone, the VmBackup holds
    #   the server's backups left open are let go: their outcome can no
    #   longer change, and a hold stops the resident's turns on the house.
    #
    # Asking (request!) and doing (step!, run by VmRollbackReleaseJob and the
    # minute sweep) are separate, so the intent survives any failure between.
    class RollbackRelease

      class Refused < StandardError; end

      NOT_RECOVERED = "Only a rollback whose resident was verified running on the house can release its server.".freeze

      # Why this attempt's server may not be deleted yet, or nil.
      def self.unadmitted_reason(rollback)
        return NOT_RECOVERED unless rollback.recovered?

        recovery = rollback.recovery.to_h
        unless rollback.swap_token.present? && recovery["swap_token"] == rollback.swap_token &&
            recovery["generation"] == rollback.generation && recovery["volume_map"] == rollback.volume_map.to_h
          return "The recovery receipt is not bound to this rollback's swap"
        end
        swap = AuditLog.where(action: "vm_rollback_swap", auditable_type: "Agent", auditable_id: rollback.agent_id)
          .where("data->>'generation' = ?", rollback.generation.to_s).order(:id).first
        unless swap && swap.data["token"] == rollback.swap_token && swap.data["volume_map"] == rollback.volume_map.to_h
          return "The swap receipt for this rollback is missing or does not match"
        end

        nil
      end

      # A person (or the house, for a disabled account) asks for the release.
      # Refused unless admitted now and the placement is still local and
      # ready; repeating it changes nothing.
      def self.request!(rollback, reason:, requested_by: nil, now: Time.current)
        recorded = rollback.with_lock do
          next false if rollback.release_requested?

          refusal = unadmitted_reason(rollback)
          raise Refused, refusal if refusal
          placement = rollback.agent_placement.reload
          unless placement.backend == "local" && placement.state == "ready"
            raise Refused, "The resident's placement is no longer the house's"
          end

          record_request!(rollback, reason:, requested_by:, now:)
          true
        end
        VmRollbackReleaseJob.perform_later(rollback.id) if recorded
        rollback
      end

      # A disabled account keeps no servers (Account#release_vm_servers). Its
      # committed and recovered attempts record the intent; step! still
      # deletes nothing until the attempt is recovered.
      def self.request_for_disabled_account!(rollback, now: Time.current)
        recorded = rollback.with_lock do
          next false if rollback.release_requested? || !%w[committed recovered].include?(rollback.phase)

          record_request!(rollback, reason: "account_disabled", requested_by: nil, now:)
          true
        end
        VmRollbackReleaseJob.perform_later(rollback.id) if recorded
      end

      def self.record_request!(rollback, reason:, requested_by:, now:)
        rollback.update!(release_requested_at: now, release_reason: reason.to_s.first(255), release_requested_by: requested_by)
        AuditLog.create!(action: "vm_rollback_release_requested", user: requested_by, account: rollback.agent.account,
          auditable: rollback.agent, data: { "rollback_id" => rollback.id, "reason" => rollback.release_reason,
            "phase" => rollback.phase, "source" => rollback.source })
      end
      private_class_method :record_request!

      def initialize(rollback, procurement: -> { ProvisionVmAgentJob.procurement_factory.call }, now: -> { Time.current })
        @rollback = rollback
        @procurement = procurement
        @now = now
      end

      # One pass, under the placement's lifecycle lock. Returns :released,
      # :releasing (the provider has not confirmed yet), :waiting (not
      # admitted, with the reason in the log), :idle (nothing asked) or :busy.
      def step!
        ProvisionVmAgentJob.exclusively(@rollback.agent_placement_id) do
          @rollback.reload
          next :released if @rollback.released?
          next :idle unless @rollback.release_requested?

          refusal = self.class.unadmitted_reason(@rollback)
          if refusal
            Rails.logger.warn("[vm_rollback_release] rollback=#{@rollback.id} waiting: #{refusal}")
            next :waiting
          end

          procurement = @procurement.call
          unresolved.each { |operation| procurement.cleanup!(operation, rollback: @rollback) }
          next :released if finish! == :released

          left = unresolved
          if left.all? { |operation| operation.state == "needs_review" && operation.provider_server_id.nil? }
            Rails.logger.warn("[vm_rollback_release] rollback=#{@rollback.id} needs an operator: " \
                              "#{left.map { |o| "#{o.public_id}:#{o.review_reason}" }.join(', ')}")
          end
          :releasing
        end
      end

      private

      def unresolved = @rollback.source_operations.unresolved.order(:id).to_a

      # Only once every purchase the attempt captured is refused or deleted,
      # read under its lock. Then the holds left by that server's backups go.
      def finish!
        swap = AuditLog.where(action: "vm_rollback_swap", auditable_type: "Agent", auditable_id: @rollback.agent_id)
          .where("data->>'generation' = ?", @rollback.generation.to_s).order(:id).first
        released = VmRollback.transaction do
          @rollback.lock!
          next false if @rollback.released? || @rollback.source_operations.unresolved.exists? || swap.nil?

          RunnerEnrollment.where(id: Array(@rollback.source["enrollment_ids"]), revoked_at: nil).find_each(&:revoke!)
          holds = release_holds!(before: swap.created_at)
          @rollback.update!(released_at: @now.call)
          AuditLog.create!(action: "vm_rollback_released", user: nil, account: @rollback.agent.account,
            auditable: @rollback.agent, data: { "rollback_id" => @rollback.id, "reason" => @rollback.release_reason,
              "procurement_operation_ids" => @rollback.source_operations.pluck(:id), "released_backup_ids" => holds })
          true
        end
        (released || @rollback.reload.released?) ? :released : :releasing
      end

      # Backups issued on this placement before the switch: nothing can be
      # issued on it after (Backup::VmResident.issue! needs a VM placement),
      # and their server is gone, so their outcome is final.
      def release_holds!(before:)
        agent = @rollback.agent
        agent.with_lock do
          VmBackup.holding.where(agent_id: agent.id)
            .joins(:runner_command).where(runner_commands: { agent_placement_id: @rollback.agent_placement_id })
            .where(runner_commands: { created_at: ..before }).lock.map do |backup|
            backup.update!(state: backup.state == "pending" ? "failed" : backup.state,
              failure_reason: backup.state == "pending" ? "VM released after a rollback" : backup.failure_reason,
              released_at: @now.call)
            backup.id
          end
        end
      end

    end
  end
end
