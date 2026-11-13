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
      guard.call(agent.reload)
      raise Agents::Sandbox::SandboxError, error if error

      @recreated += 1
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
  end

  teardown do
    VmRollback.where(agent_id: @agent.id).delete_all
    AuditLog.where(auditable: @agent).delete_all
    RunnerCommand.where(agent_placement_id: @placement.id).delete_all
    RunnerEnrollment.where(agent_placement_id: @placement.id).delete_all
    @placement.delete
    @agent.update_columns(@kept)
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
    @agent.update_columns(paused: true, volume_map: map.merge("work" => "someone-elses-work"))
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
end
