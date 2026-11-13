module Agents
  class VmMigration
    # Brings a resident that moved to its own server back to the house
    # (#426 3C rollback wiring). One VmRollback row is one attempt; step!
    # advances it one phase at a time and is safe to call again after any
    # crash or retry (Mira, jaMMNj eMaBpK):
    #
    # - start! reserves the generation ONCE, under the resident's and the
    #   placement's locks, only for a paused, inactive resident with no
    #   pending or uncertain turn, and records the exact server it ran on
    #   before anything changes. A retry never reserves again.
    # - stopping -> snapshotting: the server answered the stop; the final
    #   snapshot is asked for at this attempt's generation.
    # - snapshotting -> restoring: the house judges the snapshot against its
    #   own expectations (RemoteRuntime.rollback_snapshot_outcome).
    # - restoring -> committed: RollbackHome restores and verifies the five
    #   homes and swaps. in_commit switches the placement to local inside the
    #   swap's transaction and revokes the server's enrollments (the fence);
    #   nothing asks for the server to be deleted. A swap receipt already in
    #   the database for this generation (a crash after the commit) is
    #   adopted, never repeated.
    # - committed -> recovered: the container is recreated on the new map,
    #   and its mounts are read back from Docker and compared, destination by
    #   destination, with the five fresh volumes. Only then is the recovery
    #   receipt written, bound to the swap token, generation and map.
    #   "Running" alone is not recovery.
    # - Anything short of the commit ends in failed: the resident is as it
    #   was, stopped and paused on its server, with its placement unchanged.
    #
    # The resident stays inactive and paused throughout and after; a person
    # starts it. The server is never released here (that is a separate step,
    # admitted only by a recovered attempt).
    class Rollback
      class Refused < StandardError; end

      NOT_ON_SERVER = "Only a resident that moved to its own server and runs there can be brought back.".freeze
      NEVER_LIVED = "This resident never lived on the house, so there is nothing to bring it back to.".freeze
      UNDER_WAY = "Bringing this resident back is already under way.".freeze
      STOP_SECONDS = 15 * 60
      SNAPSHOT_SECONDS = RemoteRuntime::ROLLBACK_DEADLINE_SECONDS + 15 * 60
      MOUNTS = {
        identity: Agents::Sandbox::IDENTITY_PATH, chaos: "/home/agent/.chaos", repo: Agents::Sandbox::REPO_PATH,
        work: Agents::Sandbox::WORK_PATH, state: Agents::Sandbox::STATE_PATH
      }.freeze

      # Why this resident can't be switched now, or nil: inactive, paused,
      # no pending turn and no unfinished runtime interaction. Checked at
      # start!, at every step, and again inside the swap's transaction.
      def self.unstopped_reason(agent)
        return "The resident must be inactive and paused" if agent.active? || !agent.paused?
        if ResidentTurn.pending.where(agent:).exists? || agent.agent_runtime_interactions.where(finished_at: nil).exists?
          return "The resident has pending or uncertain execution"
        end
        return "The resident's memory is suspended" if agent.memory_vault&.suspended_at?

        nil
      end

      # The exact server this resident runs on, kept before the switch clears
      # it from the placement: the later release targets these and nothing
      # else the placement may hold by then.
      def self.source_of(placement)
        operations = placement.cloud_procurement_operations.order(:id)
        {
          "placement_id" => placement.id, "placement_generation" => placement.generation,
          "provider_server_id" => placement.provider_server_id, "location" => placement.location,
          "runtime_endpoint" => placement.runtime_endpoint,
          "procurement_operation_ids" => operations.pluck(:id),
          "provider_server_ids" => operations.where.not(provider_server_id: nil).pluck(:provider_server_id).uniq,
          "enrollment_ids" => RunnerEnrollment.where(agent_placement_id: placement.id, revoked_at: nil).order(:id).pluck(:id)
        }
      end

      def self.start!(agent, requested_by:, remote: RemoteRuntime)
        placement = AgentPlacement.uncached { AgentPlacement.find_by(agent_id: agent.id) }
        raise Refused, NOT_ON_SERVER unless placement&.migration? && placement.state == "ready"

        rollback = AgentPlacement.transaction do
          agent.lock!
          placement.lock!
          raise Refused, NOT_ON_SERVER unless placement.migration? && placement.state == "ready" && placement.provider_server_id
          raise Refused, NEVER_LIVED if placement.house_runtime_ready_at.nil?
          reason = unstopped_reason(agent)
          raise Refused, reason if reason
          raise Refused, UNDER_WAY if VmRollback.open.exists?(agent_id: agent.id)

          generation = RollbackPlan.reserve!(agent)
          rollback = VmRollback.create!(agent:, agent_placement: placement, requested_by:, generation:,
            phase: "stopping", source: source_of(placement))
          rollback.update!(stop_command: remote.stop!(agent))
          AuditLog.create!(action: "vm_rollback_started", user: requested_by, account: agent.account, auditable: agent,
            data: { "rollback_id" => rollback.id, "generation" => generation, "source" => rollback.source })
          rollback
        end
        VmRollbackJob.perform_later(rollback.id)
        rollback
      end

      def initialize(rollback, remote: RemoteRuntime, home: RollbackHome, sandbox: ->(agent) { Agents::Sandbox.new(agent) },
                     docker: Agents::BoundedCommand, now: -> { Time.current })
        @rollback = rollback
        @remote = remote
        @home = home
        @sandbox = sandbox
        @docker = docker
        @now = now
      end

      # Advances one phase. Returns the phase it leaves the attempt in.
      # Only one step runs per placement at a time (the same lifecycle lock as
      # births and cleanup); a busy lock returns :busy and changes nothing.
      def step!
        ProvisionVmAgentJob.exclusively(@rollback.agent_placement_id) do
          @rollback.reload
          case @rollback.phase
          when "stopping" then after_stop
          when "snapshotting" then after_snapshot
          when "restoring" then restore
          when "committed" then recover
          end
          @rollback.phase
        end
      end

      private

      def agent = @rollback.agent

      def after_stop
        return if still_stopped_short?

        command = @rollback.stop_command
        return fail!("The server never answered the stop") if command.nil?
        return fail!("The server did not stop the resident: #{command.state}") unless command.state == "done" || pending?(command)
        return wait_or_fail(command, STOP_SECONDS, "The server did not answer the stop in time") if pending?(command)

        snapshot = @remote.rollback_snapshot!(agent, generation: @rollback.generation)
        @rollback.update!(snapshot_command: snapshot, phase: "snapshotting", error: nil)
      rescue RemoteRuntime::Unavailable => error
        fail!(error.message)
      end

      def after_snapshot
        return if still_stopped_short?

        case snapshot
        when :pending then wait_or_fail(@rollback.snapshot_command, SNAPSHOT_SECONDS, "The server's final snapshot did not finish in time")
        when :failed then fail!("The server's final snapshot failed")
        when :mismatch then fail!("The server's final snapshot is not this resident's, at this generation")
        else
          @rollback.update!(phase: "restoring", error: nil)
          restore
        end
      end

      def restore
        return adopt!(receipt) if receipt
        return if still_stopped_short?

        taken = snapshot
        return fail!("The server's final snapshot is no longer usable") unless taken.is_a?(RollbackHome::Snapshot)

        result = @home.new(agent, generation: @rollback.generation, snapshot: taken)
          .call(in_commit: ->(locked) { switch!(locked) }, start: ->(started) { recreate!(started) })
        swap = result.swap
        if swap.ok? || swap.phase == :after_commit
          found = receipt
          return fail!("The swap reported a commit but left no receipt") unless found

          adopt!(found, error: swap.ok? ? nil : swap.error)
          recorded { verify! } if swap.ok?
        else
          fail!(swap.error)
        end
      rescue RollbackHome::Failed => error
        receipt ? adopt!(receipt, error: error.message) : fail!(error.message)
      end

      def recover
        recorded do
          recreate!(agent)
          verify!
        end
      end

      # After the commit nothing fails the attempt: it stays committed, the
      # server retained and stopped, with the error, and is tried again.
      def recorded
        yield
      rescue StandardError => error
        @rollback.update!(error: "#{error.class}: #{error.message}".first(2000))
      end

      # Inside RollbackSwap#commit!'s transaction, with the agent row locked.
      # Raising here rolls the whole swap back (before_commit).
      def switch!(locked)
        placement = AgentPlacement.lock.find(@rollback.agent_placement_id)
        source = @rollback.source
        unless placement.migration? && placement.state == "ready" &&
            placement.provider_server_id == source["provider_server_id"] && placement.generation == source["placement_generation"]
          raise Refused, "The resident's placement changed during the rollback; not switching"
        end
        reason = self.class.unstopped_reason(locked)
        raise Refused, reason if reason

        house_ready_at = placement.house_runtime_ready_at || raise(Refused, NEVER_LIVED)
        placement.update!(backend: "local", kind: nil, state: "ready", generation: placement.generation + 1,
          house_runtime_ready_at: nil, admitted_by_setting_at: nil, birth_deadline_at: nil, birth_requested_by: nil,
          cleanup_requested_at: nil, cleanup_reason: nil, first_backup_command_id: nil, provider_server_id: nil,
          location: nil, runtime_endpoint: nil, seeded_at: nil, carry: nil)
        RunnerEnrollment.where(agent_placement_id: placement.id, revoked_at: nil).find_each(&:revoke!)
        locked.update_columns(runtime_ready_at: house_ready_at, active: false, paused: true, runtime: "offline",
          health_state: "unknown", updated_at: Time.current)
      end

      def recreate!(target)
        @sandbox.call(target.reload).recreate_for_rollback!(->(locked) { recreate_guard!(locked) })
      end

      # Under the resident's row lock, before the old container is removed:
      # a retry minutes later must not tear down a container someone has
      # since activated, or one on another map, generation or placement.
      def recreate_guard!(locked)
        reason = self.class.unstopped_reason(locked)
        raise Refused, reason if reason

        expected = @rollback.volume_map.presence || receipt&.data&.dig("volume_map")
        raise Refused, "No committed volume map for this rollback" if expected.blank?
        raise Refused, "The resident is no longer on this rollback's volumes" unless locked.volume_map == expected.to_h
        unless locked.volume_rollback_generation == @rollback.generation
          raise Refused, "A newer rollback reservation superseded this attempt"
        end

        placement = @rollback.agent_placement.reload
        unless placement.backend == "local" && placement.generation == @rollback.source["placement_generation"].to_i + 1
          raise Refused, "The resident's placement changed after the rollback's switch"
        end
      end

      # The container, read back from Docker: running, and its mounts against
      # this swap's map, destination by destination: every role's fresh volume
      # at its own path, as a named volume.
      def verify!
        map = @rollback.volume_map.to_h
        agent.reload
        raise Refused, "The resident is no longer on this rollback's volumes" unless agent.volume_map == map

        container = Agents::Resources.new(agent).container
        out, _err, status = @docker.capture3("docker", "container", "inspect", "--format",
          "{{json .State.Running}} {{json .Mounts}}", container, deadline: Agents::BoundedCommand.now + 30)
        raise Refused, "Could not read the recreated container" unless status.success?

        running, mounts_json = out.strip.split(" ", 2)
        raise Refused, "The recreated container is not running" unless running == "true"

        mounts = JSON.parse(mounts_json.to_s)
        found = MOUNTS.to_h do |role, path|
          mount = mounts.find { |entry| entry["Destination"] == path }
          [ role.to_s, mount && mount["Type"] == "volume" ? mount["Name"] : nil ]
        end
        expected = MOUNTS.keys.to_h { |role| [ role.to_s, map[role.to_s] ] }
        raise Refused, "The recreated container is not on this rollback's volumes: #{found.inspect}" unless found == expected

        recovery = { "swap_token" => @rollback.swap_token, "generation" => @rollback.generation, "volume_map" => map,
                     "mounts" => found, "container" => container, "verified_at" => @now.call.iso8601 }
        VmRollback.transaction do
          @rollback.update!(phase: "recovered", recovery:, error: nil)
          AuditLog.create!(action: "vm_rollback_recovered", user: nil, account: agent.account, auditable: agent,
            data: recovery.merge("rollback_id" => @rollback.id))
        end
      end

      def adopt!(found, error: nil)
        @rollback.update!(phase: "committed", swap_token: found.data["token"], volume_map: found.data["volume_map"], error:)
      end

      def receipt
        AuditLog.where(action: "vm_rollback_swap", auditable: agent)
          .where("data->>'generation' = ?", @rollback.generation.to_s).order(:id).first
      end

      def snapshot
        command = @rollback.snapshot_command
        return :failed if command.nil?

        @remote.rollback_snapshot_outcome(command.reload, agent:, generation: @rollback.generation)
      end

      # Before the commit, every step checks the resident is still stopped
      # and this attempt still holds the latest reservation.
      def still_stopped_short?
        current = Agent.uncached { Agent.where(id: agent.id).pick(:volume_rollback_generation) }
        return fail!("A newer rollback reservation superseded this attempt") || true unless current == @rollback.generation

        reason = self.class.unstopped_reason(agent.reload)
        reason ? (fail!(reason) || true) : false
      end

      def pending?(command) = %w[queued delivered].include?(command.reload.state)

      def wait_or_fail(command, seconds, message)
        fail!(message) if @now.call > command.created_at + seconds
      end

      def fail!(message)
        @rollback.update!(phase: "failed", error: message.to_s.first(2000))
        AuditLog.create!(action: "vm_rollback_failed", user: nil, account: agent.account, auditable: agent,
          data: { "rollback_id" => @rollback.id, "generation" => @rollback.generation, "error" => @rollback.error })
        nil
      end
    end
  end
end
