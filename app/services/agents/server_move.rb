module Agents
  # Moves a resident from the server it runs on to another server the house
  # already holds (a spare), by copying the whole disk (eRyZBY, Daniel
  # 2026-11-15). It is how a resident gets a bigger machine when Hetzner will
  # not resize the one it has.
  #
  #   hold turns -> shut the old server down -> snapshot its disk ->
  #   point the house's records at the new server -> rebuild the new server
  #   from the snapshot -> its runner reports from the new server -> moved
  #
  # Why a disk copy is enough: nothing on a resident's server names the
  # server. The runner reads its server id from Hetzner's metadata service
  # every time it reports, and the house accepts a report only from the
  # server its enrollment expects. So the copy, started on the new server,
  # reports as the new server with the same runner key, and the house
  # expects exactly that once its records are switched. The resident's
  # container starts with the machine (restart unless-stopped), as after any
  # reboot.
  #
  # What it protects, and from whom:
  #
  # - The resident, from a move that loses it. The old server is only ever
  #   powered off, never changed. Until a site admin calls release!, going
  #   back is: stop the new server, switch the records back, power the old
  #   one on. Any failure after the hold begins does exactly that by itself.
  # - The resident, from running twice. Only one of the two servers is ever
  #   powered on while holding its disk: the old one is confirmed off before
  #   the snapshot, and going back confirms the new one off before the old
  #   one starts. A server that came on anyway would be refused by the house:
  #   its reports name a server the enrollment does not expect.
  # - Work in flight. A move starts only when the resident is idle in the
  #   house's own view (KernelReboot.idle?), checked under the turn admission
  #   gate, and from that moment its turns wait in the queue
  #   (ResidentTurn.admit!) until the move is settled either way.
  # - Its home. A move starts only with a verified backup newer than
  #   BACKUP_WITHIN, taken from the old server.
  #
  # What it does not do: it never deletes a server or a snapshot before
  # release!, never resizes anything, and never starts a move by itself.
  # After a move, what the resident wrote on the new server exists only
  # there; revert! says so and needs a site admin.
  class ServerMove

    class Refused < StandardError; end

    BACKUP_WITHIN = 26.hours
    # A shutdown the operating system has not finished by then gets its
    # power cut: the snapshot must be of a server that is off.
    SHUTDOWN_GRACE = 3.minutes
    PHASE_DEADLINES = {
      "stopping" => 10.minutes, "snapshotting" => 60.minutes, "rebuilding" => 60.minutes,
      "verifying" => 20.minutes
    }.freeze
    MOVE_LABEL = "souls-house/move".freeze

    NOT_ON_SERVER = "Only a resident that is running on its own server can be moved to another one.".freeze
    NOT_A_SPARE = "The server to move to must be a spare the house holds, running and not in use.".freeze
    TOO_SMALL = "The server to move to has a smaller disk than the one the resident is on.".freeze
    BUSY = "The resident is busy (a turn, a backup, a restart or a command is in flight). Try again when it is idle.".freeze
    NO_BACKUP = "The resident has no verified backup from the last #{BACKUP_WITHIN.in_hours.to_i} hours. Back it up first.".freeze
    NO_RUNNER = "The resident's server is not reporting, so its state can't be checked.".freeze
    UNDER_WAY = "A move of this resident is already under way.".freeze

    Gate = Data.define(:name, :refusal) do
      def ok? = refusal.nil?
    end

    def initialize(client: nil, procurement: nil, clock: -> { Time.current })
      @client = client
      @procurement = procurement
      @clock = clock
    end

    # Every gate with its answer, for a dry run. Reads only.
    def gates(agent, target)
      checks(agent, target).map { |name, check| Gate.new(name:, refusal: check.call) }
    end

    # Holds the resident's turns and records the move. Sends nothing to
    # Hetzner: step! does, from the job.
    def start!(agent, target:, requested_by:)
      raise Refused, "installation admin required" unless requested_by.is_a?(User) && requested_by.is_site_admin?

      move = ResidentTurn.transaction do
        ResidentTurn.connection.execute("SELECT pg_advisory_xact_lock(#{RemoteRuntime::TURN_GATE})")
        agent.lock!
        placement = AgentPlacement.lock.find_by(agent_id: agent.id)
        target = CloudProcurementOperation.lock.find(target.id)
        checks(agent, target, placement:).each_value do |check|
          reason = check.call
          raise Refused, reason if reason
        end

        source = source_operation(placement)
        enrollment = live_enrollment(placement)
        move = VmServerMove.create!(agent:, agent_placement: placement, requested_by:, source_operation: source,
          target_operation: target, runner_enrollment: enrollment, public_id: "vsm-#{SecureRandom.hex(8)}",
          phase: "stopping", source_server_id: source.provider_server_id, target_server_id: target.provider_server_id,
          phase_started_at: now)
        audit!(move, "vm_server_move_started", "source_type" => source.server_type, "target_type" => target.server_type,
          "target_location" => target.location)
        move
      end
      VmServerMoveJob.perform_later(move.id)
      move
    rescue ActiveRecord::RecordNotUnique
      raise Refused, UNDER_WAY
    end

    # Moves an open move at most one phase. Safe to call again at any time:
    # each phase reads what the provider has before it asks for anything.
    def step!(move)
      move.with_lock do
        next unless move.open?

        # Going back has no deadline: it is tried until it is done.
        if move.phase != "reverting" && now > move.phase_started_at + PHASE_DEADLINES.fetch(move.phase)
          next begin_revert!(move, "#{move.phase} did not finish in time")
        end

        case move.phase
        when "stopping" then stop!(move)
        when "snapshotting" then snapshot!(move)
        when "rebuilding" then rebuild!(move)
        when "verifying" then verify!(move)
        when "reverting" then revert_step!(move)
        end
      end
      move.reload
    rescue HetznerCloudClient::Error => e
      # A failed read or an unknown outcome proves nothing; the next step
      # reads again. The phase deadline bounds how long that can go on.
      Rails.logger.warn("[server_move] #{move.public_id} #{move.phase}: #{e.class} #{e.code}")
      move.reload
    end

    # A site admin sends a moved resident back to its old server. What it
    # did on the new server since the move stays on the new server only.
    def revert!(move, requested_by:, reason:)
      raise Refused, "installation admin required" unless requested_by.is_a?(User) && requested_by.is_site_admin?

      ResidentTurn.transaction do
        ResidentTurn.connection.execute("SELECT pg_advisory_xact_lock(#{RemoteRuntime::TURN_GATE})")
        move.agent.lock!
        move.lock!
        raise Refused, "Only a finished move whose old server is still held can be undone." unless move.phase == "moved"
        raise Refused, BUSY unless KernelReboot.idle?(move.agent, move.runner_enrollment)

        begin_revert!(move, reason.to_s.first(200).presence || "asked by a site admin")
        audit!(move, "vm_server_move_revert_asked", "by" => requested_by.id)
      end
      VmServerMoveJob.perform_later(move.id)
      move
    end

    # A site admin lets go of what the move left behind: the old server
    # after a move (or the new one after going back) and the snapshot. After
    # this the move cannot be undone.
    def release!(move, requested_by:)
      raise Refused, "installation admin required" unless requested_by.is_a?(User) && requested_by.is_site_admin?

      operation = nil
      move.with_lock do
        operation = move.left_behind_operation
        raise Refused, "Only a settled move has something to release." if operation.nil?
        if move.phase == "moved" && !healthy_on?(move, move.target_server_id)
          raise Refused, "The resident is not reporting from its new server, so its old one is kept."
        end
      end

      client.snapshot_ids_labelled(MOVE_LABEL, move.public_id).each { |image_id| client.delete_snapshot(image_id) }
      operation = procurement.request_delete!(operation, requested_by:) if %w[provisioned needs_review].include?(operation.state)
      CloudProcurementReconcileJob.perform_later(operation.id)
      move.with_lock { move.enter!("released", now:, released_at: now) }
      audit!(move, "vm_server_move_released", "by" => requested_by.id, "operation" => operation.public_id)
      move
    end

    private

    def now = @clock.call
    def client = @client ||= HetznerCloudClient.from_credentials
    def procurement = @procurement ||= CloudProcurement.from_credentials

    def checks(agent, target, placement: nil)
      placement ||= AgentPlacement.uncached { AgentPlacement.find_by(agent_id: agent.id) }
      source = placement && source_operation(placement)
      enrollment = placement && live_enrollment(placement)
      {
        "Runs on its own server" => lambda do
          NOT_ON_SERVER unless placement&.backend == "hetzner_cloud" && placement.state == "ready" &&
            !placement.cleanup_requested? && agent.runtime_ready_at.present? && source
        end,
        "No move under way" => -> { UNDER_WAY if VmServerMove.open.exists?(agent_id: agent.id) },
        "The target is a spare the house holds" => lambda do
          NOT_A_SPARE unless target&.spare? && target.state == "provisioned" && target.provider_server_id.present? &&
            !VmServerMove.open.exists?(target_operation_id: target.id)
        end,
        "The target's disk is big enough" => lambda do
          TOO_SMALL if source && target && disk_gb(target.server_type) < disk_gb(source.server_type)
        end,
        "Its server is reporting" => -> { NO_RUNNER unless enrollment&.healthy?(now:) },
        "A recent verified backup exists" => lambda do
          NO_BACKUP unless VmBackup.where(agent_id: agent.id, state: "verified").where(updated_at: (now - BACKUP_WITHIN)..).exists?
        end,
        "The resident is idle" => -> { BUSY unless enrollment && KernelReboot.idle?(agent, enrollment) }
      }
    end

    def disk_gb(type) = Billing::Tier::MACHINES.dig(type, :disk_gb).to_i

    # The one purchase whose server the placement names.
    def source_operation(placement)
      return nil if placement.provider_server_id.nil?

      placement.cloud_procurement_operations.find_by(state: "provisioned", provider_server_id: placement.provider_server_id)
    end

    # The enrollment the placement's server reports through.
    def live_enrollment(placement)
      RunnerEnrollment.where(agent_placement_id: placement.id, revoked_at: nil).where.not(enrolled_at: nil)
        .where(expected_provider_server_id: placement.provider_server_id).order(:id).last
    end

    # --- forward ------------------------------------------------------------

    # Shutdown and power-off can be asked twice without harm, so an unknown
    # outcome is simply asked again on the next step.
    def stop!(move)
      server = client.find_server(move.source_server_id)
      return begin_revert!(move, "the old server is gone") if server.nil?
      return move.enter!("snapshotting", now:) if server.status == "off"

      if move.stop_requested_at.nil?
        client.shutdown_server(move.source_server_id)
        move.update!(stop_requested_at: now)
      elsif move.poweroff_requested_at.nil? && now > move.stop_requested_at + SHUTDOWN_GRACE
        client.poweroff_server(move.source_server_id)
        move.update!(poweroff_requested_at: now)
      end
    end

    def snapshot!(move)
      server = client.find_server(move.source_server_id)
      return begin_revert!(move, "the old server is gone") if server.nil?
      # A copy of a running disk is not a copy to trust.
      return begin_revert!(move, "the old server was started during the copy") if server.status == "running"

      if move.snapshot_image_id.nil?
        known = client.snapshot_ids_labelled(MOVE_LABEL, move.public_id)
        if known.any?
          move.update!(snapshot_image_id: known.max)
        else
          image_id, action = client.create_snapshot(move.source_server_id,
            description: "move #{move.public_id} of resident #{move.agent_id}", labels: { MOVE_LABEL => move.public_id })
          move.update!(snapshot_image_id: image_id, snapshot_action_id: action.id)
        end
        return
      end

      action = snapshot_action(move)
      return if action.nil? || action.status == "running"
      return begin_revert!(move, "the snapshot failed (#{action.error_code || 'no code'})") unless action.status == "success"

      # From here the house expects the new server. The old one is off, so
      # nothing reports in between.
      switch!(move, to: :target)
      move.enter!("rebuilding", now:, switched_at: now)
    end

    def snapshot_action(move)
      if move.snapshot_action_id
        client.find_action(move.snapshot_action_id)
      else
        action = client.server_actions(move.source_server_id, "create_image").last
        move.update!(snapshot_action_id: action.id) if action
        action
      end
    end

    def rebuild!(move)
      if move.rebuild_action_id.nil?
        # A rebuild asked for before a crash is read back, not asked twice.
        known = client.server_actions(move.target_server_id, "rebuild_server")
          .select { |action| action.id > move.snapshot_action_id.to_i }
        action = known.last || client.rebuild_server(move.target_server_id, image: move.snapshot_image_id)
        move.update!(rebuild_action_id: action.id)
        return
      end

      action = client.find_action(move.rebuild_action_id)
      return if action.nil? || action.status == "running"
      return begin_revert!(move, "the rebuild failed (#{action.error_code || 'no code'})") unless action.status == "success"

      move.enter!("verifying", now:, rebuilt_at: now)
    end

    def verify!(move)
      server = client.find_server(move.target_server_id)
      return begin_revert!(move, "the new server is gone") if server.nil?
      client.poweron_server(move.target_server_id) if server.status == "off"
      return unless healthy_on?(move, move.target_server_id, since: move.switched_at)

      move.enter!("moved", now:, verified_at: now)
      audit!(move, "vm_server_move_finished", "target_server_id" => move.target_server_id)
      ResidentTurnDispatchJob.perform_later
    end

    # The enrollment has reported from that server, recently, from a boot
    # that began after the given moment.
    def healthy_on?(move, server_id, since: nil)
      enrollment = move.runner_enrollment.reload
      facts = enrollment.last_facts.is_a?(Hash) ? enrollment.last_facts : {}
      return false unless enrollment.healthy?(now:) && facts["provider_server_id"] == server_id
      return true if since.nil?

      uptime = facts["uptime_seconds"]
      uptime.is_a?(Integer) && enrollment.last_heartbeat_at - uptime.seconds >= since - 1.minute &&
        enrollment.last_heartbeat_at >= since
    end

    # --- going back -----------------------------------------------------------

    def begin_revert!(move, reason)
      move.enter!("reverting", now:, revert_reason: reason.to_s.first(255), failure: (reason.to_s.first(255) unless move.phase == "moved"))
      audit!(move, "vm_server_move_reverting", "reason" => reason.to_s.first(255))
    end

    # Power-off and power-on are asked again on each step until the server
    # says so; Hetzner answers "locked" while one is in progress, which the
    # caller reads as "not yet".
    def revert_step!(move)
      # The copy must be off before the old server starts: never both.
      if move.switched? || move.rebuild_action_id
        target = client.find_server(move.target_server_id)
        return client.poweroff_server(move.target_server_id) if target && target.status != "off"
      end
      if move.switched?
        switch!(move, to: :source)
        move.update!(switched_at: nil)
      end

      source = client.find_server(move.source_server_id)
      if source.nil?
        Rails.logger.error("[server_move] #{move.public_id}: old server #{move.source_server_id} is gone; needs an operator")
        return
      end
      return client.poweron_server(move.source_server_id) if source.status == "off"
      return unless healthy_on?(move, move.source_server_id, since: move.phase_started_at)

      move.enter!("reverted", now:)
      audit!(move, "vm_server_move_reverted", "reason" => move.revert_reason)
      ResidentTurnDispatchJob.perform_later
    end

    # --- records ------------------------------------------------------------

    # Points the placement, its purchase and its runner's enrollment at one
    # server, and sets the other server's purchase aside with no placement.
    # One transaction: the house never expects two servers, or none.
    def switch!(move, to:)
      taking, leaving = to == :target ? [ move.target_operation, move.source_operation ] : [ move.source_operation, move.target_operation ]
      AgentPlacement.transaction do
        placement = AgentPlacement.lock.find(move.agent_placement_id)
        leaving = CloudProcurementOperation.lock.find(leaving.id)
        taking = CloudProcurementOperation.lock.find(taking.id)
        enrollment = RunnerEnrollment.lock.find(move.runner_enrollment_id)
        unless placement.provider_server_id == leaving.provider_server_id && leaving.agent_placement_id == placement.id &&
            taking.agent_placement_id.nil? && taking.state == "provisioned" && leaving.state == "provisioned"
          raise Refused, "the servers are not as this move recorded them"
        end

        # The leaving purchase first: a placement has one unresolved purchase.
        leaving.update!(purpose: "move_source", agent_placement: nil, placement_label: leaving.provider_placement_label)
        taking.update!(purpose: "placement", agent_placement: placement, placement_generation: placement.generation,
          requested_by: taking.requested_by || move.requested_by, placement_label: taking.provider_placement_label)
        placement.update!(provider_server_id: taking.provider_server_id, location: taking.location)
        enrollment.update!(expected_provider_server_id: taking.provider_server_id, procurement_operation_id: taking.id)
        audit!(move, "vm_server_move_switched", "to" => to.to_s, "server_id" => taking.provider_server_id)
      end
    end

    def audit!(move, action, **data)
      AuditLog.create!(action:, user: move.requested_by, account: move.agent.account, auditable: move.agent,
        data: { "move" => move.public_id, "source_server_id" => move.source_server_id,
                "target_server_id" => move.target_server_id }.merge(data.transform_keys(&:to_s)))
    end

  end
end
