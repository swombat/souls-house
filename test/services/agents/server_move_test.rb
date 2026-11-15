require "test_helper"

module Agents
  class ServerMoveTest < ActiveJob::TestCase

    IMAGE_ID = 161_547_269
    OLD = 4242
    NEW = 5151

    # Stands in for HetznerCloudClient: two servers with a power state, and
    # actions that finish when the test says so.
    class FakeHetzner

      Server = Struct.new(:id, :status)
      attr_reader :calls, :servers, :snapshots
      attr_accessor :fail_next

      def initialize(*ids)
        @servers = ids.to_h { |id| [ id, Server.new(id, "running") ] }
        @actions = {}
        @snapshots = {}
        @calls = []
        @next = 100
      end

      def find_server(id) = @servers[id]
      def find_action(id) = @actions[id]

      def shutdown_server(id) = act(id, "shutdown_server") { @servers[id].status = "off" }
      def poweroff_server(id) = act(id, "stop_server") { @servers[id].status = "off" }
      def poweron_server(id) = act(id, "start_server") { @servers[id].status = "running" }
      def rebuild_server(id, image:) = act(id, "rebuild_server", image) { @servers[id].status = "running" }

      def create_snapshot(id, description:, labels: {})
        action = act(id, "create_image")
        @snapshots[@next += 1] = labels
        [ @next, action ]
      end

      def snapshot_ids_labelled(key, value) = @snapshots.select { |_id, labels| labels[key] == value }.keys

      def delete_snapshot(id)
        @calls << [ :delete_snapshot, id ]
        @snapshots.delete(id)
        true
      end

      def server_actions(id, command) = @actions.values.select { |action| action.server == id && action.command == command }

      # Finishes every running action; a block decides the outcome.
      def settle!(status = "success")
        @actions.each_value do |action|
          next unless action.status == "running"

          action.status = status
          action.effect&.call if status == "success"
        end
      end

      Pending = Struct.new(:id, :server, :command, :status, :error_code, :effect)

      private

      def act(id, command, detail = nil, &effect)
        if fail_next
          error = fail_next
          self.fail_next = nil
          raise error
        end
        @calls << [ command, id, detail ].compact
        action = Pending.new(@next += 1, id, command, "running", nil, effect)
        @actions[action.id] = action
      end

    end

    setup do
      @admin = users(:site_admin_user)
      @agent = agents(:research_assistant)
      @agent.update!(runtime: "external", runtime_ready_at: 2.days.ago, uuid: SecureRandom.uuid_v7)
      @placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready",
        provider_server_id: OLD, location: "fsn1")
      @source = operation!(server_type: "cx23", location: "fsn1", server_id: OLD, agent_placement: @placement,
        requested_by: @admin)
      @target = operation!(server_type: "cx33", location: "nbg1", server_id: NEW, purpose: "spare", placement_label: "spare")
      @enrollment, token = RunnerEnrollment.mint!(placement: @placement, operation_id: @source.id)
      @enrollment.confirm_provider_server!(OLD)
      @enrollment.enroll!(token:, public_key: Base64.strict_encode64("k" * 32), reported_server_id: OLD, facts: {},
        nonce: SecureRandom.hex(16))
      report_from(OLD, uptime: 86_400)
      command = RunnerCommand.enqueue!(enrollment: @enrollment, kind: "backup_resident", payload: {})
      command.update_columns(state: "done", finished_at: 1.hour.ago)
      VmBackup.create!(agent: @agent, runner_command: command, checkpoint_file_digest: "d" * 64, state: "verified",
        deadline_at: 1.hour.ago, released_at: 1.hour.ago)
      @hetzner = FakeHetzner.new(OLD, NEW)
      @mover = ServerMove.new(client: @hetzner, procurement: nil)
    end

    def operation!(server_type:, location:, server_id:, **attributes)
      id = SecureRandom.hex(4)
      CloudProcurementOperation.create!(public_id: "cpo-#{id}", approval_reference: "test", server_type:, location:,
        image_id: IMAGE_ID, ssh_key_ids: [ 101 ], provider_name: "souls-house-#{id}", state: "provisioned",
        provider_server_id: server_id, **attributes)
    end

    def report_from(server_id, uptime: 30)
      @enrollment.reload.update!(last_heartbeat_at: Time.current,
        last_facts: { "provider_server_id" => server_id, "uptime_seconds" => uptime })
    end

    def start! = @mover.start!(@agent, target: @target, requested_by: @admin)

    # Steps until the phase stops changing, finishing provider actions between steps.
    def run_to(move, phase)
      12.times do
        return move if move.reload.phase == phase

        @mover.step!(move)
        @hetzner.settle!
      end
      flunk "move stopped at #{move.phase}, wanted #{phase}"
    end

    test "a move copies the disk to the spare, switches the records, and leaves the old server off and untouched" do
      move = start!
      assert_equal "stopping", move.phase
      assert_includes VmServerMove.holding_agent_ids, @agent.id
      assert_enqueued_with(job: VmServerMoveJob, args: [ move.id ])

      run_to(move, "verifying")
      assert_equal [ [ "shutdown_server", OLD ], [ "create_image", OLD ], [ "rebuild_server", NEW, move.snapshot_image_id ] ],
        @hetzner.calls
      assert_equal "off", @hetzner.find_server(OLD).status

      # The records point at the new server before it has reported.
      assert_equal [ NEW, "nbg1" ], @placement.reload.values_at(:provider_server_id, :location)
      assert_equal [ "placement", @placement.id, "spare" ],
        @target.reload.values_at(:purpose, :agent_placement_id, :provider_placement_label)
      assert_equal [ "move_source", nil, @placement.id.to_s ],
        @source.reload.values_at(:purpose, :agent_placement_id, :provider_placement_label)
      assert_equal NEW, @enrollment.reload.expected_provider_server_id

      # Not moved until the runner reports from the new server, from a boot after the switch.
      @mover.step!(move)
      assert_equal "verifying", move.reload.phase
      report_from(OLD)
      @mover.step!(move)
      assert_equal "verifying", move.reload.phase

      report_from(NEW)
      @mover.step!(move)
      assert_equal "moved", move.reload.phase
      assert_not_includes VmServerMove.holding_agent_ids, @agent.id
      assert_enqueued_with(job: ResidentTurnDispatchJob)
      assert_equal 0, SpareServers.new.status[:counted]
      assert_equal %w[vm_server_move_started vm_server_move_switched vm_server_move_finished],
        AuditLog.where(auditable: @agent).where("action LIKE 'vm_server_move%'").order(:id).pluck(:action)
    end

    test "a turn that arrives during a move stays queued, and is admitted once the move is settled" do
      move = start!
      interaction = AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake", session_id: "s",
        started_at: Time.current, endpoint_url: "runner://#{@enrollment.public_id}")
      turn = ResidentTurn.create!(agent: @agent, agent_runtime_interaction: interaction, dispatch_id: SecureRandom.uuid,
        session_id: "s", payload: "{}", state: "queued")

      ResidentTurn.stub(:capacity, 1) { assert_not_includes ResidentTurn.admit!, turn.id }
      assert_equal "queued", turn.reload.state

      # Settled, admission takes the same turn up again (and decides it).
      move.update_columns(phase: "moved")
      ResidentTurn.stub(:capacity, 1) { ResidentTurn.admit! }
      assert_not_equal "queued", turn.reload.state
    end

    test "each gate refuses with its reason and nothing is recorded" do
      refusals = lambda do
        @mover.gates(@agent, @target).reject(&:ok?).map(&:refusal)
      end
      assert_empty refusals.call

      VmBackup.update_all(updated_at: 2.days.ago)
      assert_equal [ ServerMove::NO_BACKUP ], refusals.call
      VmBackup.update_all(updated_at: Time.current)

      turn_command = RunnerCommand.enqueue!(enrollment: @enrollment, kind: "start_resident", payload: {})
      assert_equal [ ServerMove::BUSY ], refusals.call
      assert_raises(ServerMove::Refused) { start! }
      turn_command.update_columns(state: "done", finished_at: Time.current)

      @enrollment.update!(last_heartbeat_at: 10.minutes.ago)
      assert_includes refusals.call, ServerMove::NO_RUNNER
      report_from(OLD)

      small = operation!(server_type: "cx23", location: "hel1", server_id: 6001, purpose: "spare", placement_label: "spare")
      big = operation!(server_type: "cx43", location: "hel1", server_id: 6002, purpose: "spare", placement_label: "spare")
      @source.update_columns(server_type: "cx33")
      assert_equal [ ServerMove::TOO_SMALL ], @mover.gates(@agent, small).reject(&:ok?).map(&:refusal)
      assert_empty @mover.gates(@agent, big).reject(&:ok?)

      assert_equal [ ServerMove::NOT_A_SPARE ], @mover.gates(@agent, @source).reject(&:ok?).map(&:refusal).uniq
      assert_raises(ServerMove::Refused) { @mover.start!(@agent, target: @target, requested_by: users(:regular_user)) }
      assert_equal 0, VmServerMove.count
    end

    test "one open move per resident, and a spare is the target of one move" do
      start!
      assert_raises(ServerMove::Refused) { start! }
      assert_equal 1, VmServerMove.count
    end

    test "a shutdown the machine ignores gets its power cut after the grace" do
      move = start!
      @mover.step!(move)
      assert_equal [ [ "shutdown_server", OLD ] ], @hetzner.calls
      @mover.step!(move)
      assert_equal 1, @hetzner.calls.size

      travel(ServerMove::SHUTDOWN_GRACE + 1.second) { @mover.step!(move) }
      assert_equal [ "stop_server", OLD ], @hetzner.calls.last
      @hetzner.settle!
      @mover.step!(move)
      assert_equal "snapshotting", move.reload.phase
    end

    test "a failed snapshot goes back: nothing was switched, the old server is started and reports again" do
      move = start!
      run_to(move, "snapshotting")
      @mover.step!(move)
      @hetzner.settle!("error")
      @mover.step!(move)
      assert_equal "reverting", move.reload.phase
      assert_equal OLD, @placement.reload.provider_server_id

      @mover.step!(move)
      assert_equal [ "start_server", OLD ], @hetzner.calls.last
      @hetzner.settle!
      @mover.step!(move)
      assert_equal "reverting", move.reload.phase

      travel(1.minute) do
        report_from(OLD)
        @mover.step!(move)
      end
      assert_equal "reverted", move.reload.phase
      assert_match(/snapshot failed/, move.failure)
      assert_not @hetzner.calls.any? { |call| call.first == "rebuild_server" }
      assert_equal "spare", @target.reload.purpose
    end

    test "a failed rebuild goes back: the copy is powered off before the old server starts, and the records return" do
      move = start!
      run_to(move, "rebuilding")
      @mover.step!(move)
      @hetzner.settle!("error")
      @hetzner.find_server(NEW).status = "running"
      @mover.step!(move)
      assert_equal "reverting", move.reload.phase
      assert_equal NEW, @placement.reload.provider_server_id

      @mover.step!(move)
      assert_equal [ "stop_server", NEW ], @hetzner.calls.last
      assert_equal NEW, @placement.reload.provider_server_id, "the records stay until the copy is off"
      assert_not @hetzner.calls.any? { |call| call == [ "start_server", OLD ] }
      @hetzner.settle!

      @mover.step!(move)
      assert_equal [ OLD, "fsn1" ], @placement.reload.values_at(:provider_server_id, :location)
      assert_equal [ "placement", @placement.id ], @source.reload.values_at(:purpose, :agent_placement_id)
      assert_equal [ "move_source", nil, "spare" ], @target.reload.values_at(:purpose, :agent_placement_id, :provider_placement_label)
      assert_equal OLD, @enrollment.reload.expected_provider_server_id
      assert_equal [ "start_server", OLD ], @hetzner.calls.last
      @hetzner.settle!

      travel(1.minute) do
        report_from(OLD)
        @mover.step!(move)
      end
      assert_equal "reverted", move.reload.phase
      # The spare now holds a copy of a resident's disk: it is not a spare again.
      assert_equal 0, CloudProcurementOperation.spares.count
    end

    test "a new server that never reports goes back after the verifying deadline" do
      move = start!
      run_to(move, "verifying")
      travel(ServerMove::PHASE_DEADLINES["verifying"] + 1.minute) { @mover.step!(move) }
      assert_equal "reverting", move.reload.phase
      assert_match(/verifying did not finish/, move.failure)
    end

    test "a crash after the rebuild was asked reads the action back and never asks twice" do
      move = start!
      run_to(move, "rebuilding")
      @mover.step!(move)
      move.update_columns(rebuild_action_id: nil)

      @mover.step!(move)
      assert_equal 1, @hetzner.calls.count { |call| call.first == "rebuild_server" }
      assert_not_nil move.reload.rebuild_action_id
    end

    test "a crash after the snapshot was asked adopts it by its label" do
      move = start!
      run_to(move, "snapshotting")
      @mover.step!(move)
      image = move.reload.snapshot_image_id
      move.update_columns(snapshot_image_id: nil, snapshot_action_id: nil)

      @mover.step!(move)
      assert_equal image, move.reload.snapshot_image_id
      assert_equal 1, @hetzner.calls.count { |call| call.first == "create_image" }
    end

    test "a provider error leaves the move where it is for the next step" do
      move = start!
      @hetzner.fail_next = HetznerCloudClient::ActionOutcomeUnknown.new("lost", code: "action_outcome_unknown")
      assert_equal "stopping", @mover.step!(move).phase
      assert_nil move.reload.stop_requested_at

      @mover.step!(move)
      assert_equal [ [ "shutdown_server", OLD ] ], @hetzner.calls
    end

    test "a site admin sends a moved resident back, and only while it is idle" do
      move = start!
      run_to(move, "verifying")
      report_from(NEW)
      @mover.step!(move)
      assert_equal "moved", move.reload.phase

      assert_raises(ServerMove::Refused) { @mover.revert!(move, requested_by: users(:regular_user), reason: "x") }
      @mover.revert!(move, requested_by: @admin, reason: "the disk did not grow")
      assert_equal "reverting", move.reload.phase
      assert_nil move.failure
      assert_includes VmServerMove.holding_agent_ids, @agent.id

      run_to(move, "reverting")
      3.times do
        @mover.step!(move)
        @hetzner.settle!
      end
      assert_equal "off", @hetzner.find_server(NEW).status
      assert_equal OLD, @placement.reload.provider_server_id
      travel(1.minute) do
        report_from(OLD)
        @mover.step!(move)
      end
      assert_equal "reverted", move.reload.phase
    end

    test "release deletes the snapshot and the old server, only once the resident reports from the new one" do
      deleted = []
      procurement = Object.new
      procurement.define_singleton_method(:request_delete!) do |operation, requested_by:|
        deleted << [ operation.id, requested_by.id ]
        operation
      end
      mover = ServerMove.new(client: @hetzner, procurement:)
      move = start!
      assert_raises(ServerMove::Refused) { mover.release!(move, requested_by: @admin) }

      run_to(move, "verifying")
      report_from(NEW)
      @mover.step!(move)
      @enrollment.update!(last_heartbeat_at: 10.minutes.ago)
      assert_raises(ServerMove::Refused) { mover.release!(move, requested_by: @admin) }
      assert_empty deleted

      report_from(NEW)
      mover.release!(move, requested_by: @admin)
      assert_equal "released", move.reload.phase
      assert_equal [ [ @source.id, @admin.id ] ], deleted
      assert_empty @hetzner.snapshots
      assert_raises(ServerMove::Refused) { mover.revert!(move, requested_by: @admin, reason: "too late") }
    end

    test "the job steps an open move and comes back; the sweep restarts one left without a job" do
      move = start!
      clear_enqueued_jobs
      ServerMove.stub(:new, @mover) { VmServerMoveJob.perform_now(move.id) }
      assert_enqueued_with(job: VmServerMoveJob, args: [ move.id ])

      clear_enqueued_jobs
      move.update_columns(updated_at: 2.minutes.ago)
      VmBirthSweepJob.perform_now
      assert_enqueued_with(job: VmServerMoveJob, args: [ move.id ])
    end

  end
end
