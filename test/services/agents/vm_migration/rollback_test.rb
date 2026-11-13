require "test_helper"

# The rollback driver (#426 3C wiring): one attempt from a resident on its
# server back to the house. Real runner commands, the real RollbackSwap; a
# fake restore (RollbackHome is tested on its own), a fake sandbox and a fake
# docker inspect. Outside transactional fixtures, as the swap requires.
class Agents::VmMigration::RollbackTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  ROLES = Agents::VmMigration::RollbackPlan::ROLES
  HEX = "a" * 64
  KEPT = %w[active paused runtime uuid volume_map volume_rollback_generation runtime_ready_at health_state
            restic_password container_name].freeze

  # Stands in for RollbackHome: no restic, no volumes, but the real swap
  # with the driver's in_commit and start.
  class FakeHome

    class << self

      attr_accessor :calls, :raise_with

    end

    def initialize(agent, generation:, snapshot:)
      @agent = agent
      @generation = generation
      @snapshot = snapshot
    end

    def call(in_commit:, start:)
      self.class.calls += 1
      raise Agents::VmMigration::RollbackHome::Failed, self.class.raise_with if self.class.raise_with

      plan = Agents::VmMigration::RollbackPlan.new(@agent, generation: @generation)
      swap = Agents::VmMigration::RollbackSwap.new(@agent, plan:, verified: ROLES.index_with(true), in_commit:, start:,
        evidence: { "snapshot_id" => @snapshot.snapshot_id }).call
      Agents::VmMigration::RollbackHome::Result.new(generation: @generation, verified: {}, shapes: {}, swap:)
    end

  end

  Status = Struct.new(:ok) do
    def success? = ok
  end

  # docker container inspect --format {{json .Mounts}}: the agent's current
  # map at the sandbox's paths, unless told otherwise.
  class FakeDocker

    attr_accessor :mounts, :running

    def initialize(agent)
      @agent = agent
      @running = true
    end

    def capture3(*_argv, deadline:)
      mounts = @mounts || Agents::VmMigration::Rollback::MOUNTS.map do |role, path|
        { "Type" => "volume", "Name" => @agent.reload.volume_map[role.to_s], "Destination" => path }
      end
      [ "#{running} #{JSON.generate(mounts)}", "", Status.new(true) ]
    end

  end

  # Same public entry as Agents::Sandbox (checked below): runs the guard
  # under no lock, then counts or fails the recreate.
  class FakeSandbox

    attr_accessor :error, :recreated, :agent

    def initialize(agent)
      @agent = agent
      @recreated = 0
    end

    def recreate_for_rollback!(guard)
      # A test's hook into the post-commit start, set without a public
      # accessor so the fake's interface still matches the real Sandbox.
      @before&.call
      guard.call(agent.reload)
      raise Agents::Sandbox::SandboxError, error if error

      @recreated += 1
    end

  end

  # The provider, for the release: deletes are recorded and the server goes.
  class FakeClient

    attr_reader :deletes
    attr_accessor :servers, :linger

    def initialize(servers)
      @servers = servers
      @deletes = []
    end

    def find_server(id) = servers[id]
    def find_action(_id) = nil

    def delete_server(id, placement_id:)
      @deletes << [ id, placement_id ]
      servers.delete(id) unless linger
      HetznerCloudClient::DeleteAccepted.new(server_id: id, action_id: 900 + @deletes.size, action_status: "running")
    end

  end

  setup do
    FakeHome.calls = 0
    FakeHome.raise_with = nil
    @agent = agents(:research_assistant)
    @kept = @agent.attributes.slice(*KEPT)
    @house_ready_at = 3.days.ago.change(usec: 0)
    @agent.update_columns(active: false, paused: true, uuid: SecureRandom.uuid, volume_map: nil, volume_rollback_generation: 0,
      restic_password: "synthetic-restic-password", container_name: "souls-house-agent-rollback", runtime_ready_at: nil)
    @placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", kind: "migration", state: "ready",
      provider_server_id: 4343, house_runtime_ready_at: @house_ready_at)
    @enrollment, token = RunnerEnrollment.mint!(placement: @placement)
    @enrollment.confirm_provider_server!(4343)
    @enrollment.enroll!(token:, public_key: Base64.strict_encode64("k" * 32), reported_server_id: 4343, facts: {}, nonce: SecureRandom.hex(16))
    @enrollment.heartbeat!(reported_server_id: 4343, facts: {}, nonce: SecureRandom.hex(16))
    @sandbox = FakeSandbox.new(@agent)
    @docker = FakeDocker.new(@agent)
    @user = users(:existing_user)
    @operation = CloudProcurementOperation.create!(agent_placement: @placement, requested_by: @user, state: "provisioned",
      public_id: SecureRandom.uuid, provider_name: "sh-rollback-#{SecureRandom.hex(4)}", approval_reference: "test",
      location: "fsn1", server_type: "cx23", image_id: 1, ssh_key_ids: [ 1 ], provider_server_id: 4343)
    @client = FakeClient.new({ 4343 => Object.new })
    @created = []
  end

  teardown do
    @created.reverse_each { |record| record.class.where(id: record.id).delete_all }
    VmBackup.where(agent_id: @agent.id).delete_all
    VmRollback.where(agent_id: @agent.id).delete_all
    CloudProcurementOperation.where(agent_placement_id: @placement.id).delete_all
    AuditLog.where(auditable: @agent).delete_all
    RunnerCommand.where(agent_placement_id: @placement.id).delete_all
    RunnerEnrollment.where(agent_placement_id: @placement.id).delete_all
    @placement.delete
    @agent.update_columns(@kept)
  end

  def track(record)
    @created << record
    record
  end

  def release(rollback) = Agents::VmMigration::RollbackRelease.new(rollback,
    procurement: -> { CloudProcurement.new(client: @client, config: CloudProcurement::Config.new(image_id: 1, ssh_key_ids: [ 1 ],
      locations: %w[fsn1], rails_url: "https://souls.example")) }).step!

  # A whole rollback, to recovered.
  def recovered
    rollback = to_restoring
    assert_equal "recovered", full { driver(rollback).step! }
    rollback.reload
  end

  # A backup the server was taking when the rollback stopped it: its outcome
  # never came back, so it holds the resident.
  def held_backup
    command = RunnerCommand.enqueue!(enrollment: @enrollment, kind: "backup_resident", payload: { "fake" => "backup" })
    VmBackup.create!(agent: @agent, runner_command: command, checkpoint_file_digest: HEX, deadline_at: 10.minutes.from_now)
  end

  def driver(rollback) = Agents::VmMigration::Rollback.new(rollback, home: FakeHome, sandbox: ->(_agent) { @sandbox }, docker: @docker)

  def full(&block) = RunnerBundle.stub(:full_running?, true, &block)

  def answer(command, result: {}, outcome: "done")
    command.deliver!(now: Time.current)
    command.record_result!({ "outcome" => outcome, "result" => result }, now: Time.current)
    command.reload
  end

  def snapshot_result(rollback, **overrides)
    { "container_name" => @agent.container_name, "agent_uuid" => @agent.uuid, "generation" => rollback.generation,
      "snapshot_id" => HEX, "tools_stopped" => true,
      "shapes" => ROLES.each_with_index.to_h { |role, index| [ role.to_s, { "entries" => index, "shape" => %w[a b c d e][index] * 64 } ] }
    }.merge(overrides.transform_keys(&:to_s))
  end

  # start!, the stop answered, the snapshot asked for and answered.
  def to_restoring(**result)
    rollback = Agents::VmMigration::Rollback.start!(@agent, requested_by: @user)
    answer(rollback.stop_command)
    full { driver(rollback).step! }
    rollback.reload
    answer(rollback.snapshot_command, result: snapshot_result(rollback, **result))
    rollback
  end

  test "a whole rollback: stop, final snapshot, swap with the placement switch, recreate, mounts read back" do
    rollback = Agents::VmMigration::Rollback.start!(@agent, requested_by: @user)
    assert_equal "stopping", rollback.phase
    assert_equal 1, rollback.generation
    assert_equal "stop_resident", rollback.stop_command.kind
    assert_equal 4343, rollback.source["provider_server_id"]
    assert_equal [ @enrollment.id ], rollback.source["enrollment_ids"]
    assert_equal @placement.generation, rollback.source["placement_generation"]

    assert_equal "stopping", full { driver(rollback).step! }, "waits while the stop is unanswered"
    answer(rollback.stop_command)
    assert_equal "snapshotting", full { driver(rollback).step! }
    assert_equal "rollback_snapshot", rollback.reload.snapshot_command.kind

    answer(rollback.snapshot_command, result: snapshot_result(rollback))
    assert_equal "recovered", full { driver(rollback).step! }

    rollback.reload
    placement = @placement.reload
    assert_equal [ "local", "ready", nil, nil, nil, nil ],
      [ placement.backend, placement.state, placement.kind, placement.provider_server_id, placement.location, placement.runtime_endpoint ]
    assert_equal rollback.source["placement_generation"] + 1, placement.generation
    assert_nil placement.cleanup_requested_at, "no server deletion is asked for"
    assert @enrollment.reload.revoked_at, "the server is fenced"
    assert Agents::RuntimeLocation.local?(@agent)

    @agent.reload
    assert_equal [ false, true ], [ @agent.active?, @agent.paused? ]
    assert_equal @house_ready_at, @agent.runtime_ready_at
    assert_equal 1, @sandbox.recreated
    receipt = AuditLog.find_by!(action: "vm_rollback_swap", auditable: @agent)
    assert_equal receipt.data["token"], rollback.swap_token
    assert_equal @agent.volume_map, rollback.volume_map
    assert_equal rollback.swap_token, rollback.recovery["swap_token"]
    assert_equal rollback.generation, rollback.recovery["generation"]
    assert_equal @agent.volume_map, rollback.recovery["mounts"]
    assert AuditLog.exists?(action: "vm_rollback_recovered", auditable: @agent)
  end

  test "start! refuses a running or unpaused resident, one not on its server, and a second attempt" do
    @agent.update_columns(paused: false)
    assert_raises(Agents::VmMigration::Rollback::Refused) { Agents::VmMigration::Rollback.start!(@agent, requested_by: @user) }
    @agent.update_columns(paused: true, active: true)
    assert_raises(Agents::VmMigration::Rollback::Refused) { Agents::VmMigration::Rollback.start!(@agent, requested_by: @user) }
    @agent.update_columns(active: false)

    Agents::VmMigration::Rollback.start!(@agent, requested_by: @user)
    error = assert_raises(Agents::VmMigration::Rollback::Refused) { Agents::VmMigration::Rollback.start!(@agent, requested_by: @user) }
    assert_equal Agents::VmMigration::Rollback::UNDER_WAY, error.message
    assert_equal 1, @agent.reload.volume_rollback_generation, "a refused start reserves nothing"

    VmRollback.where(agent_id: @agent.id).update_all(phase: "failed")
    @placement.update_columns(kind: nil)
    assert_raises(Agents::VmMigration::Rollback::Refused) { Agents::VmMigration::Rollback.start!(@agent, requested_by: @user) }
  end

  test "a recreate that fails leaves the attempt committed and the server retained; a later step recovers without a second swap" do
    rollback = to_restoring
    @sandbox.error = "docker: no space left"
    assert_equal "committed", full { driver(rollback).step! }
    rollback.reload
    assert_match "no space left", rollback.error
    assert_nil rollback.recovery
    assert_equal "local", @placement.reload.backend
    assert_nil @placement.cleanup_requested_at

    @sandbox.error = nil
    assert_equal "recovered", full { driver(rollback).step! }
    assert_equal 1, FakeHome.calls
    assert_equal 1, AuditLog.where(action: "vm_rollback_swap", auditable: @agent).count
  end

  test "the fake sandbox's entry is public on the real Sandbox, with the same arity" do
    (FakeSandbox.public_instance_methods(false) - [ :error, :error=, :recreated, :recreated=, :agent, :agent= ]).each do |name|
      assert Agents::Sandbox.public_method_defined?(name), "Agents::Sandbox##{name} must be public"
      assert_equal Agents::Sandbox.instance_method(name).arity, FakeSandbox.instance_method(name).arity
    end
  end

  test "the real Sandbox runs the guard under the row lock before removing anything, and spawns an inactive resident" do
    @placement.update_columns(backend: "local", kind: nil, provider_server_id: nil)
    @agent.update_columns(runtime: "offline")
    sandbox = Agents::Sandbox.new(@agent.reload)
    calls = []
    sandbox.stub(:remove!, ->(**) { calls << :remove }) do
      sandbox.stub(:spawn_without_portability_gate!, -> { calls << :spawn }) do
        sandbox.stub(:container_exists?, false) do
          refused = ->(_locked) { raise Agents::VmMigration::Rollback::Refused, "no" }
          assert_raises(Agents::VmMigration::Rollback::Refused) { sandbox.recreate_for_rollback!(refused) }
          assert_empty calls, "a refused guard removes nothing"

          seen = nil
          sandbox.recreate_for_rollback!(->(locked) { seen = [ locked.active?, Agent.connection.transaction_open? ] })
          assert_equal [ false, true ], seen, "the guard sees the inactive resident inside the lock"
          assert_equal %i[remove spawn], calls, "spawned without the activation gate"
        end
      end
    end
  end

  test "a retry refuses before recreating once the resident is activated, unpaused, busy or on another map" do
    rollback = to_restoring
    @sandbox.error = "docker: no space left"
    assert_equal "committed", full { driver(rollback).step! }
    @sandbox.error = nil
    map = @agent.reload.volume_map

    @agent.update_columns(active: true)
    assert_equal "committed", full { driver(rollback.reload).step! }
    assert_match "inactive and paused", rollback.reload.error
    @agent.update_columns(active: false, paused: false)
    assert_equal "committed", full { driver(rollback.reload).step! }
    @agent.update_columns(paused: true)

    # Busy for real: a turn whose outcome is still open, then one queued.
    interaction = track(AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake", session_id: SecureRandom.uuid,
      started_at: Time.current, endpoint_url: "https://runtime.example.test"))
    assert_equal "committed", full { driver(rollback.reload).step! }
    assert_match "pending or uncertain execution", rollback.reload.error
    turn = track(ResidentTurn.enqueue!(interaction, { session_id: interaction.session_id, request: "wake" }))
    interaction.update_columns(finished_at: Time.current)
    assert ResidentTurn.pending.exists?(turn.id), "the turn is queued, not finished"
    assert_equal "committed", full { driver(rollback.reload).step! }
    assert_match "pending or uncertain execution", rollback.reload.error
    turn.update_columns(finished_at: Time.current)

    @agent.update_columns(volume_map: map.merge("work" => "someone-elses-work"))
    assert_equal "committed", full { driver(rollback.reload).step! }
    assert_match "no longer on this rollback's volumes", rollback.reload.error
    @agent.update_columns(volume_map: map)
    @placement.update_columns(generation: @placement.reload.generation + 1)
    assert_equal "committed", full { driver(rollback.reload).step! }
    assert_match "placement changed", rollback.reload.error
    assert_equal 0, @sandbox.recreated, "nothing was torn down by a refused retry"

    @placement.update_columns(generation: @placement.generation - 1)
    assert_equal "recovered", full { driver(rollback.reload).step! }
  end

  test "a container that is not running is not recovery, whatever its mounts" do
    rollback = to_restoring
    @docker.running = false
    assert_equal "committed", full { driver(rollback).step! }
    assert_match "not running", rollback.reload.error
    assert_nil rollback.recovery
    @docker.running = true
    assert_equal "recovered", full { driver(rollback).step! }
  end

  test "mounts that are not this swap's map are not recovery" do
    rollback = to_restoring
    @docker.mounts = Agents::VmMigration::Rollback::MOUNTS.map do |role, path|
      { "Type" => "volume", "Name" => Agents::Resources.new(@agent).derived_volumes.fetch(role), "Destination" => path }
    end
    assert_equal "committed", full { driver(rollback).step! }
    assert_match "not on this rollback's volumes", rollback.reload.error
    assert_nil rollback.recovery

    @docker.mounts = nil
    @docker.mounts = Agents::VmMigration::Rollback::MOUNTS.map do |role, path|
      name = @agent.reload.volume_map[role.to_s]
      { "Type" => role == :work ? "bind" : "volume", "Name" => name, "Destination" => path }
    end
    assert_equal "committed", full { driver(rollback).step! }, "a bind mount of the right name is not the volume"
  end

  test "a crash after the commit is adopted from the receipt, never swapped again" do
    rollback = to_restoring
    full { driver(rollback).step! }
    rollback.reload.update_columns(phase: "restoring", swap_token: nil, volume_map: nil, recovery: nil)

    assert_equal "committed", full { driver(rollback).step! }
    assert_equal 1, FakeHome.calls
    assert_equal AuditLog.find_by!(action: "vm_rollback_swap", auditable: @agent).data["token"], rollback.reload.swap_token
  end

  test "before the commit, a newer reservation, an unpaused resident or a bad snapshot fails the attempt and changes nothing" do
    rollback = Agents::VmMigration::Rollback.start!(@agent, requested_by: @user)
    answer(rollback.stop_command)
    Agents::VmMigration::RollbackPlan.reserve!(@agent)
    assert_equal "failed", full { driver(rollback).step! }
    assert_match "newer rollback reservation", rollback.reload.error

    VmRollback.where(agent_id: @agent.id).delete_all
    rollback = to_restoring
    @agent.update_columns(paused: false)
    assert_equal "failed", full { driver(rollback).step! }
    @agent.update_columns(paused: true)

    VmRollback.where(agent_id: @agent.id).delete_all
    rollback = to_restoring(generation: 999)
    assert_equal "failed", full { driver(rollback).step! }
    assert_match "not this resident's", rollback.reload.error

    assert_equal 0, FakeHome.calls
    assert_equal [ "hetzner_cloud", 4343 ], [ @placement.reload.backend, @placement.provider_server_id ]
    assert_nil @enrollment.reload.revoked_at
    assert_nil @agent.reload.volume_map
  end

  test "a placement changed during the restore is not switched: the whole swap rolls back" do
    rollback = to_restoring
    @placement.update_columns(provider_server_id: 9999)
    assert_equal "failed", full { driver(rollback).step! }
    assert_match "placement changed", rollback.reload.error
    assert_nil @agent.reload.volume_map
    assert_equal "hetzner_cloud", @placement.reload.backend
    assert_not AuditLog.exists?(action: "vm_rollback_swap", auditable: @agent)
  end

  test "a restore that fails before the swap fails the attempt" do
    rollback = to_restoring
    FakeHome.raise_with = "restic restore of the work home failed"
    assert_equal "failed", full { driver(rollback).step! }
    assert_equal "restic restore of the work home failed", rollback.reload.error
    assert_equal "hetzner_cloud", @placement.reload.backend
  end

  test "VmCleanupJob never retires a placement a rollback made local" do
    rollback = to_restoring
    full { driver(rollback).step! }
    @placement.reload.update_columns(cleanup_requested_at: Time.current, cleanup_reason: "test")
    VmCleanupJob.perform_now(@placement.id)
    assert_equal [ "local", "ready" ], [ @placement.reload.backend, @placement.state ]
    assert Agents::RuntimeLocation.local?(@agent)
  end

  test "the release deletes the server the rollback recorded, then lets go of the holds its backups left" do
    backup = held_backup
    rollback = recovered
    assert Backup::VmResident.held?(@agent), "the unanswered backup still holds the resident"

    Agents::VmMigration::RollbackRelease.request!(rollback, reason: "rolled back", requested_by: @user)
    assert rollback.reload.release_requested?
    assert_nil @placement.reload.cleanup_requested_at, "the placement is not handed to VmCleanupJob"

    @client.linger = true
    assert_equal :releasing, release(rollback), "deleting: not confirmed until the server is absent"
    assert_equal [ [ 4343, @placement.id.to_s ] ], @client.deletes
    assert_equal "deleting", @operation.reload.state
    assert_not rollback.reload.released?
    assert Backup::VmResident.held?(@agent), "no hold is let go before the server is gone"

    @client.servers.delete(4343)
    assert_equal :released, release(rollback)
    assert_equal "deleted", @operation.reload.state
    assert rollback.reload.released?
    assert_equal [ "local", "ready", nil ], [ @placement.reload.backend, @placement.state, @placement.provider_server_id ]
    assert Agents::RuntimeLocation.local?(@agent), "the resident stays on the house"
    assert_equal [ "failed", "VM released after a rollback" ], [ backup.reload.state, backup.failure_reason ]
    assert_not Backup::VmResident.held?(@agent)
    assert AuditLog.exists?(action: "vm_rollback_released", auditable: @agent)

    assert_equal :released, release(rollback), "repeating changes nothing"
    assert_equal 1, @client.deletes.size
  end

  test "a committed rollback whose recreate failed keeps its server, even when the release was asked for" do
    rollback = to_restoring
    @sandbox.error = "docker: no space left"
    assert_equal "committed", full { driver(rollback).step! }

    error = assert_raises(Agents::VmMigration::RollbackRelease::Refused) do
      Agents::VmMigration::RollbackRelease.request!(rollback.reload, reason: "rolled back", requested_by: @user)
    end
    assert_equal Agents::VmMigration::RollbackRelease::NOT_RECOVERED, error.message

    # Account#disable!'s own callback, without the rest of disabling (this
    # test runs outside a transaction).
    @agent.account.send(:release_vm_servers)
    assert rollback.reload.release_requested?, "a disabled account records the intent"
    assert_equal "account_disabled", rollback.release_reason
    assert_equal :waiting, release(rollback)
    assert_empty @client.deletes
    assert_equal "provisioned", @operation.reload.state

    @sandbox.error = nil
    assert_equal "recovered", full { driver(rollback.reload).step! }
    assert_equal :released, release(rollback)
    assert_equal [ [ 4343, @placement.id.to_s ] ], @client.deletes
  end

  test "an account disabled while the rollback is restoring keeps its cleanup intent across the switch" do
    rollback = to_restoring
    assert rollback.open? && rollback.phase != "committed", "not yet switched"

    # Disabling lands before the switch: the cleanup is asked of the server
    # placement, and the attempt is not yet committed.
    @agent.account.send(:release_vm_servers)
    assert_equal "account_disabled", @placement.reload.cleanup_reason
    assert_not rollback.reload.release_requested?

    @sandbox.error = "docker: no space left"
    assert_equal "committed", full { driver(rollback).step! }
    assert_equal [ "local", nil ], [ @placement.reload.backend, @placement.cleanup_requested_at ]
    assert rollback.reload.release_requested?, "the switch carries the intent onto the attempt"
    assert_equal "account_disabled", rollback.release_reason
    assert AuditLog.where(action: "vm_rollback_release_requested", auditable: @agent)
      .where("data->>'carried_from_placement' = 'true'").exists?
    assert_includes VmRollback.releasing, rollback, "the minute sweep owns it now"

    assert_equal :waiting, release(rollback), "nothing is deleted before the resident is verified running"
    assert_empty @client.deletes
    assert_equal "provisioned", @operation.reload.state

    @sandbox.error = nil
    assert_equal "recovered", full { driver(rollback.reload).step! }
    assert_equal :released, release(rollback)
    assert_equal [ [ 4343, @placement.id.to_s ] ], @client.deletes
    assert_equal [ "local", "ready", nil ], [ @placement.reload.backend, @placement.state, @placement.cleanup_requested_at ]
  end

  test "an account disabled after the swap commits but before the attempt is adopted records the intent" do
    rollback = to_restoring
    seen = nil
    # The post-commit start: the placement is already the house's and the
    # attempt is not yet marked committed.
    @sandbox.instance_variable_set(:@before, lambda do
      @sandbox.instance_variable_set(:@before, nil)
      seen = [ @placement.reload.backend, rollback.reload.phase ]
      @agent.account.send(:release_vm_servers)
    end)
    @sandbox.error = "docker: no space left"
    assert_equal "committed", full { driver(rollback).step! }
    assert_equal [ "local", "restoring" ], seen, "the disable landed in the interval"

    assert_nil @placement.reload.cleanup_requested_at, "no flag on the house's placement"
    assert rollback.reload.release_requested?, "the restoring, already swapped attempt records the intent"
    assert_equal "account_disabled", rollback.release_reason
    assert_equal :waiting, release(rollback), "nothing is deleted before the resident is verified running"
    assert_empty @client.deletes

    @sandbox.error = nil
    assert_equal "recovered", full { driver(rollback.reload).step! }
    assert_equal :released, release(rollback)
    assert_equal [ [ 4343, @placement.id.to_s ] ], @client.deletes
  end

  test "an account disabled before the swap does not ask the attempt itself" do
    rollback = to_restoring
    rollback.update_columns(phase: "restoring") # restoring, the swap not yet committed
    assert_equal [ "hetzner_cloud", 4343 ], [ @placement.reload.backend, @placement.provider_server_id ]
    Agents::VmMigration::RollbackRelease.request_for_disabled_account!(rollback)
    assert_not rollback.reload.release_requested?, "the placement still holds the server and owns its cleanup"
  end

  test "a cleanup asked of a placement a rollback has already made local changes nothing" do
    rollback = recovered
    @placement.reload.request_cleanup!("account_disabled")
    assert_nil @placement.reload.cleanup_requested_at
    assert_not rollback.reload.release_requested?
  end

  test "the release reaches only the purchases the rollback recorded" do
    rollback = recovered
    Agents::VmMigration::RollbackRelease.request!(rollback, reason: "rolled back", requested_by: @user)
    @operation.update_columns(state: "deleted")
    later = CloudProcurementOperation.create!(agent_placement: @placement, requested_by: @user, state: "provisioned",
      public_id: SecureRandom.uuid, provider_name: "sh-later-#{SecureRandom.hex(4)}", approval_reference: "test",
      location: "fsn1", server_type: "cx23", image_id: 1, ssh_key_ids: [ 1 ], provider_server_id: 5151)
    @client.servers[5151] = Object.new
    procurement = CloudProcurement.new(client: @client, config: CloudProcurement::Config.new(image_id: 1, ssh_key_ids: [ 1 ],
      locations: %w[fsn1], rails_url: "https://souls.example"))
    assert_raises(CloudProcurement::NotAllowed, "refused while the release is still open") do
      procurement.cleanup!(later, rollback: rollback.reload)
    end

    assert_equal :released, release(rollback)
    assert_empty @client.deletes, "a purchase made after the switch is not this rollback's"
    assert_equal "provisioned", later.reload.state
  end

  test "the release needs a recovery bound to the swap receipt" do
    rollback = recovered
    rollback.update_columns(recovery: rollback.recovery.merge("swap_token" => "another-swap"))
    assert_raises(Agents::VmMigration::RollbackRelease::Refused) do
      Agents::VmMigration::RollbackRelease.request!(rollback.reload, reason: "rolled back", requested_by: @user)
    end
    rollback.update_columns(release_requested_at: Time.current)
    assert_equal :waiting, release(rollback.reload)
    assert_empty @client.deletes
  end

  test "a purchase still being reconciled is left for an operator, never written onto the local placement" do
    rollback = recovered
    Agents::VmMigration::RollbackRelease.request!(rollback, reason: "rolled back", requested_by: @user)
    @operation.update_columns(state: "reconciling")
    procurement = CloudProcurement.new(client: @client, config: CloudProcurement::Config.new(image_id: 1, ssh_key_ids: [ 1 ],
      locations: %w[fsn1], rails_url: "https://souls.example"))
    assert_raises(CloudProcurement::NotAllowed) { procurement.cleanup!(@operation, rollback: rollback.reload) }
    assert_nil @placement.reload.provider_server_id
  end

  test "the minute sweep keeps an unconfirmed release going" do
    rollback = recovered
    Agents::VmMigration::RollbackRelease.request!(rollback, reason: "rolled back", requested_by: @user)
    enqueued = []
    VmRollbackReleaseJob.stub(:perform_later, ->(id) { enqueued << id }) { VmBirthSweepJob.perform_now }
    assert_includes enqueued, rollback.id
    rollback.update_columns(released_at: Time.current)
    enqueued.clear
    VmRollbackReleaseJob.stub(:perform_later, ->(id) { enqueued << id }) { VmBirthSweepJob.perform_now }
    assert_not_includes enqueued, rollback.id
  end

  # docker for the house volume release: volumes by name with their labels
  # and the containers using them; removals are recorded.
  class FakeVolumes

    attr_reader :volumes, :removed
    attr_accessor :time_out_on, :die_after_rm_of, :time_out_after_rm_of

    def initialize
      @volumes = {}
      @removed = []
    end

    def add(name, rollback: "", checkout: LocalInstance.current.fingerprint, users: "")
      @volumes[name] = { rollback:, checkout:, users: }
    end

    def call(*argv)
      name = argv.last
      case argv[1, 2]
      in [ "volume", "inspect" ]
        volume = @volumes[name]
        return [ "", "Error: No such volume: #{name}", Status.new(false) ] unless volume

        [ "#{volume[:rollback]}|#{volume[:checkout]}\n", "", Status.new(true) ]
      in [ "ps", "-a" ]
        [ @volumes.dig(name.delete_prefix("volume="), :users).to_s, "", Status.new(true) ]
      in [ "volume", "rm" ]
        raise Agents::BoundedCommand::TimedOut if name == time_out_on

        @removed << name
        @volumes.delete(name)
        raise "the process died after Docker removed #{name}" if name == die_after_rm_of
        raise Agents::BoundedCommand::TimedOut if name == time_out_after_rm_of

        [ "", "", Status.new(true) ]
      end
    end

  end

  HouseVolumeRelease = Agents::VmMigration::HouseVolumeRelease

  # The resident's derived house volumes, and the rollback's live ones with
  # their rollback label.
  def seed_house_volumes(rollback, fake)
    derived = Agents::Resources.new(@agent.reload).derived_volumes
    derived.each_value { |name| fake.add(name) }
    rollback.volume_map.each_value { |name| fake.add(name, rollback: "#{@agent.uuid}/#{rollback.generation}/#{'f' * 16}") }
    derived
  end

  def volume_release(rollback, fake, at:, guard: -> { }) = HouseVolumeRelease.new(rollback, docker: fake, guard:, now: -> { at })

  def after_hold(rollback) = Time.iso8601(rollback.recovery["verified_at"]) + HouseVolumeRelease::HOLD + 1.minute

  test "the house volumes a recovered rollback replaced are removed after the hold, and only those" do
    rollback = recovered
    fake = FakeVolumes.new
    derived = seed_house_volumes(rollback, fake)

    error = assert_raises(HouseVolumeRelease::Refused) { volume_release(rollback, fake, at: Time.current).release!(by: @user) }
    assert_match "kept until", error.message
    assert_empty fake.removed

    outcomes = volume_release(rollback, fake, at: after_hold(rollback)).release!(by: @user)
    assert_equal derived.values.sort, fake.removed.sort
    assert_equal [ :removed ], outcomes.map(&:status).uniq
    assert rollback.volume_map.values.all? { |name| fake.volumes.key?(name) }, "the live map is untouched"
    receipts = AuditLog.where(action: "house_volume_released", auditable: @agent)
    assert_equal derived.values.sort, receipts.map { |receipt| receipt.data["volume"] }.sort
    assert_equal [ @user.id ], receipts.map(&:user_id).uniq

    again = volume_release(rollback, fake, at: after_hold(rollback)).release!(by: @user)
    assert_equal [ :absent ], again.map(&:status).uniq
    assert_equal 5, fake.removed.size
  end

  test "a rollback that is committed but not recovered removes nothing" do
    rollback = to_restoring
    @sandbox.error = "docker: no space left"
    assert_equal "committed", full { driver(rollback).step! }
    rollback.reload
    fake = FakeVolumes.new
    seed_house_volumes(rollback, fake)

    assert_raises(HouseVolumeRelease::Refused) { volume_release(rollback, fake, at: 30.days.from_now).release!(by: @user) }
    assert_empty fake.removed
  end

  test "an earlier attempt's leftovers go too, only with this resident's rollback label for that generation" do
    @agent.update_columns(volume_rollback_generation: 1) # reserved by an attempt that failed before its swap
    rollback = recovered
    assert_equal 2, rollback.generation
    fake = FakeVolumes.new
    derived = seed_house_volumes(rollback, fake)
    leftovers = derived.transform_values { |name| "#{name}-rb1" }
    leftovers.except(:work).each_value { |name| fake.add(name, rollback: "#{@agent.uuid}/1/#{'e' * 16}") }
    fake.add(leftovers[:work], rollback: "#{SecureRandom.uuid}/1/#{'e' * 16}")

    outcomes = volume_release(rollback, fake, at: after_hold(rollback)).release!(by: @user).index_by(&:name)
    assert_equal (derived.values + leftovers.except(:work).values).sort, fake.removed.sort
    assert_equal :foreign, outcomes.fetch(leftovers[:work]).status
    assert rollback.volume_map.values.all? { |name| fake.volumes.key?(name) }, "the live map is untouched"
  end

  test "a volume a container still uses, or another checkout's, is left where it is" do
    rollback = recovered
    fake = FakeVolumes.new
    derived = seed_house_volumes(rollback, fake)
    fake.add(derived[:repo], users: "abc123\n")
    fake.add(derived[:state], checkout: "another-checkout")

    outcomes = volume_release(rollback, fake, at: after_hold(rollback)).release!(by: @user).index_by(&:name)
    assert_equal :in_use, outcomes.fetch(derived[:repo]).status
    assert_equal :foreign, outcomes.fetch(derived[:state]).status
    assert_equal derived.values_at(:identity, :chaos, :work).sort, fake.removed.sort
  end

  test "nothing is removed once the resident leaves this map, a newer rollback is reserved, or the placement moves on" do
    rollback = recovered
    fake = FakeVolumes.new
    seed_house_volumes(rollback, fake)
    at = after_hold(rollback)
    [
      -> { @agent.update_columns(volume_map: nil) },
      -> { @agent.update_columns(volume_rollback_generation: rollback.generation + 1) },
      -> { @placement.update_columns(generation: @placement.generation + 1) },
      -> { @placement.update_columns(state: "pending") }
    ].each do |change|
      agent_before = @agent.reload.attributes.slice("volume_map", "volume_rollback_generation")
      placement_before = @placement.reload.attributes.slice("generation", "state")
      change.call
      assert_raises(HouseVolumeRelease::Refused) { volume_release(rollback, fake, at:).release!(by: @user) }
      @agent.update_columns(agent_before)
      @placement.update_columns(placement_before)
    end
    assert_empty fake.removed
    assert_equal 5, volume_release(rollback, fake, at:).release!(by: @user).count { |outcome| outcome.status == :removed }
  end

  test "a Docker timeout partway keeps the receipts of the volumes already removed" do
    rollback = recovered
    fake = FakeVolumes.new
    derived = seed_house_volumes(rollback, fake)
    fake.time_out_on = derived[:repo]

    outcomes = volume_release(rollback, fake, at: after_hold(rollback)).release!(by: @user).index_by(&:name)
    assert_equal :unknown, outcomes.fetch(derived[:repo]).status
    removed = derived.values - [ derived[:repo] ]
    assert_equal removed.sort, fake.removed.sort
    assert_equal removed.sort, AuditLog.where(action: "house_volume_released", auditable: @agent).map { |r| r.data["volume"] }.sort
  end

  test "a volume found already gone without a removal receipt is recorded once" do
    rollback = recovered
    fake = FakeVolumes.new
    derived = seed_house_volumes(rollback, fake)
    fake.volumes.delete(derived[:work]) # removed by hand, or by an rm whose answer was lost

    2.times { volume_release(rollback, fake, at: after_hold(rollback)).release!(by: @user) }
    witnesses = AuditLog.where(action: "house_volume_found_absent", auditable: @agent)
    assert_equal [ derived[:work] ], witnesses.map { |r| r.data["volume"] }
    assert_equal 4, AuditLog.where(action: "house_volume_released", auditable: @agent).count
  end

  test "a non-local Docker endpoint refuses the release before any Docker call or record" do
    rollback = recovered
    fake = FakeVolumes.new
    seed_house_volumes(rollback, fake)
    remote = -> { raise Agents::Resources::OwnershipError, "Local instances require a Unix-socket Docker endpoint; refusing remote Docker" }
    calls = []
    spy = ->(*argv) { calls << argv; fake.call(*argv) }

    assert_raises(Agents::Resources::OwnershipError) do
      HouseVolumeRelease.new(rollback, docker: spy, guard: remote, now: -> { after_hold(rollback) }).release!(by: @user)
    end
    assert_empty calls
    assert_empty fake.removed
    assert_not AuditLog.where(auditable: @agent).where("action LIKE 'house_volume%'").exists?
  end

  test "the endpoint guard runs again before each removal" do
    rollback = recovered
    fake = FakeVolumes.new
    derived = seed_house_volumes(rollback, fake)
    checks = 0
    guard = -> { checks += 1; raise Agents::Resources::OwnershipError, "remote Docker" if checks > 3 }

    assert_raises(Agents::Resources::OwnershipError) { volume_release(rollback, fake, at: after_hold(rollback), guard:).release!(by: @user) }
    assert_equal 2, fake.removed.size
    assert_equal 3, AuditLog.where(action: "house_volume_release_intended", auditable: @agent).count
  end

  test "an intent committed before rm survives a crash and attributes the removal on the next run" do
    rollback = recovered
    fake = FakeVolumes.new
    derived = seed_house_volumes(rollback, fake)
    fake.die_after_rm_of = derived[:repo]
    admin = users(:site_admin_user)

    assert_raises(RuntimeError) { volume_release(rollback, fake, at: after_hold(rollback)).release!(by: @user) }
    assert_not fake.volumes.key?(derived[:repo])
    intents = AuditLog.where(action: "house_volume_release_intended", auditable: @agent).where("data->>'volume' = ?", derived[:repo])
    assert_equal [ @user.id ], intents.map(&:user_id)
    assert_not AuditLog.where(action: "house_volume_released", auditable: @agent).where("data->>'volume' = ?", derived[:repo]).exists?

    fake.die_after_rm_of = nil
    outcomes = volume_release(rollback, fake, at: after_hold(rollback)).release!(by: admin).index_by(&:name)
    assert_equal :absent, outcomes.fetch(derived[:repo]).status
    receipt = AuditLog.where(action: "house_volume_released", auditable: @agent).where("data->>'volume' = ?", derived[:repo]).sole
    assert_equal @user.id, receipt.user_id, "attributed to whoever asked for the rm, not the run that found it gone"
    assert_equal intents.first.id, receipt.data["intent_id"]
    assert receipt.data["reconciled"]
    assert_not AuditLog.where(action: "house_volume_found_absent", auditable: @agent).exists?
    assert_equal derived.values.sort, AuditLog.where(action: "house_volume_released", auditable: @agent).map { |r| r.data["volume"] }.sort

    released = AuditLog.where(action: "house_volume_released", auditable: @agent).index_by { |r| r.data["volume"] }
    released.each_value { |r| assert_equal r.user_id, AuditLog.find(r.data["intent_id"]).user_id }
  end

  test "an rm whose answer is lost after Docker acted is reported unknown, then reconciled to its intent" do
    rollback = recovered
    fake = FakeVolumes.new
    derived = seed_house_volumes(rollback, fake)
    fake.time_out_after_rm_of = derived[:chaos]

    outcomes = volume_release(rollback, fake, at: after_hold(rollback)).release!(by: @user).index_by(&:name)
    assert_equal :unknown, outcomes.fetch(derived[:chaos]).status
    assert_equal 4, AuditLog.where(action: "house_volume_released", auditable: @agent).count
    intent = AuditLog.where(action: "house_volume_release_intended", auditable: @agent).where("data->>'volume' = ?", derived[:chaos]).sole

    fake.time_out_after_rm_of = nil
    volume_release(rollback, fake, at: after_hold(rollback)).release!(by: users(:site_admin_user))
    receipt = AuditLog.where(action: "house_volume_released", auditable: @agent).where("data->>'volume' = ?", derived[:chaos]).sole
    assert_equal [ intent.id, @user.id, true ], [ receipt.data["intent_id"], receipt.user_id, receipt.data["reconciled"] ]
  end

  test "after a second rollback the original set is released along with the first rollback's" do
    @agent.update_columns(volume_rollback_generation: 1)
    rollback = recovered
    fake = FakeVolumes.new
    derived = seed_house_volumes(rollback, fake)
    first = derived.transform_values { |name| "#{name}-rb1" }
    first.each_value { |name| fake.add(name, rollback: "#{@agent.uuid}/1/#{'e' * 16}") }
    swap = AuditLog.find_by!(action: "vm_rollback_swap", auditable: @agent)
    swap.update_columns(data: swap.data.merge("previous_map" => first.transform_keys(&:to_s)))

    volume_release(rollback, fake, at: after_hold(rollback)).release!(by: @user)
    assert_equal (derived.values + first.values).sort, fake.removed.sort
    assert rollback.volume_map.values.all? { |name| fake.volumes.key?(name) }, "the live map is untouched"
  end

  test "asking again after a full release writes no further intents" do
    rollback = recovered
    fake = FakeVolumes.new
    seed_house_volumes(rollback, fake)
    volume_release(rollback, fake, at: after_hold(rollback)).release!(by: @user)
    intents = AuditLog.where(action: "house_volume_release_intended", auditable: @agent).count

    volume_release(rollback, fake, at: after_hold(rollback)).release!(by: @user)
    assert_equal intents, AuditLog.where(action: "house_volume_release_intended", auditable: @agent).count
  end

  test "a recorded name that is not this resident's own refuses the whole release" do
    rollback = recovered
    swap = AuditLog.find_by!(action: "vm_rollback_swap", auditable: @agent)
    derived = Agents::Resources.new(@agent.reload).derived_volumes.transform_keys(&:to_s)
    swap.update_columns(data: swap.data.merge("previous_map" => derived.merge("identity" => "hk-agent-someone-else-identity")))
    fake = FakeVolumes.new
    seed_house_volumes(rollback, fake)

    error = assert_raises(HouseVolumeRelease::Refused) { volume_release(rollback, fake, at: after_hold(rollback)).release!(by: @user) }
    assert_match "not this resident's identity volume", error.message
    assert_empty fake.removed
  end

end
