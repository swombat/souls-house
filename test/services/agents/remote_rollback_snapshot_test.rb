require "test_helper"

module Agents
  # The house half of the server's final snapshot before a rollback
  # (#426 3C): when it may be asked for, and how its answer is judged.
  class RemoteRollbackSnapshotTest < ActiveSupport::TestCase

    ROLES = %w[identity chaos repo work state].freeze
    HEX = "a" * 64

    setup do
      @agent = agents(:research_assistant)
      @agent.update!(restic_password: "synthetic-restic-password", uuid: SecureRandom.uuid, container_name: "souls-house-agent-rollback")
      @placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4242)
      @enrollment, token = RunnerEnrollment.mint!(placement: @placement)
      @enrollment.confirm_provider_server!(4242)
      @enrollment.enroll!(token:, public_key: Base64.strict_encode64("k" * 32), reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
      @enrollment.heartbeat!(reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
      @generation = VmMigration::RollbackPlan.reserve!(@agent)
    end

    def answered(kind, outcome: "done", result: {})
      command = RunnerCommand.enqueue!(enrollment: @enrollment, kind:, payload: { "container_name" => @agent.container_name })
      command.deliver!(now: Time.current)
      command.record_result!({ "outcome" => outcome, "result" => result }, now: Time.current)
      command.reload
    end

    def full(value = true, &block)
      RunnerBundle.stub(:full_running?, value, &block)
    end

    def good_result(**overrides)
      { "container_name" => @agent.container_name, "agent_uuid" => @agent.uuid, "generation" => @generation,
        "snapshot_id" => HEX, "tools_stopped" => true, "already" => false, "duration_ms" => 5,
        "shapes" => ROLES.each_with_index.to_h { |role, index| [ role, { "entries" => index, "shape" => %w[a b c d e][index] * 64 } ] }
      }.merge(overrides.transform_keys(&:to_s))
    end

    test "asks for the snapshot only for the reserved generation, on the full package, after a stop that answered done" do
      answered("stop_resident")
      command = full { RemoteRuntime.rollback_snapshot!(@agent, generation: @generation) }
      assert_equal "rollback_snapshot", command.kind
      assert_equal "queued", command.state
      payload = JSON.parse(command.payload_json)
      assert_equal %w[agent_uuid container_name deadline_seconds generation restic_password], payload.keys.sort
      assert_equal @agent.uuid, payload["agent_uuid"]
      assert_equal @agent.container_name, payload["container_name"]
      assert_equal @generation, payload["generation"]
      assert_equal @agent.restic_password, payload["restic_password"]
      assert_equal RemoteRuntime::ROLLBACK_DEADLINE_SECONDS, payload["deadline_seconds"]
    end

    test "refuses a generation that is not a positive integer or no longer the latest reservation" do
      answered("stop_resident")
      full do
        [ 0, -1, "1", nil, 1.0 ].each do |bad|
          assert_raises(ArgumentError, bad.inspect) { RemoteRuntime.rollback_snapshot!(@agent, generation: bad) }
        end
        newer = VmMigration::RollbackPlan.reserve!(@agent)
        error = assert_raises(RemoteRuntime::Unavailable) { RemoteRuntime.rollback_snapshot!(@agent, generation: @generation) }
        assert_match(/latest reservation/, error.message)
        assert RemoteRuntime.rollback_snapshot!(@agent, generation: newer)
      end
    end

    test "refuses a resident without a well-formed uuid" do
      answered("stop_resident")
      @agent.update_columns(uuid: nil)
      full do
        error = assert_raises(RemoteRuntime::Unavailable) { RemoteRuntime.rollback_snapshot!(@agent.reload, generation: @generation) }
        assert_match(/uuid/, error.message)
      end
    end

    test "refuses a runner not on the full package" do
      answered("stop_resident")
      full(false) do
        error = assert_raises(RemoteRuntime::Unavailable) { RemoteRuntime.rollback_snapshot!(@agent, generation: @generation) }
        assert_match(/full package/, error.message)
      end
      assert_not RunnerCommand.where(kind: "rollback_snapshot").exists?
    end

    test "refuses unless the newest lifecycle command is a stop that answered done" do
      refuse = lambda do |label|
        full do
          error = assert_raises(RemoteRuntime::Unavailable, label) { RemoteRuntime.rollback_snapshot!(@agent, generation: @generation) }
          assert_match(/not been stopped/, error.message, label)
        end
      end
      refuse.("no stop at all")
      answered("start_resident")
      refuse.("only a start")
      answered("stop_resident", outcome: "failed")
      refuse.("a stop that failed")
      stop = RunnerCommand.enqueue!(enrollment: @enrollment, kind: "stop_resident", payload: { "container_name" => @agent.container_name })
      refuse.("a stop still queued")
      stop.deliver!(now: Time.current)
      stop.record_result!({ "outcome" => "done" }, now: Time.current)
      RunnerCommand.enqueue!(enrollment: @enrollment, kind: "start_resident", payload: { "container_name" => @agent.container_name })
      refuse.("a start queued after the stop")
      assert_not RunnerCommand.where(kind: "rollback_snapshot").exists?
    end

    test "an answer becomes the executor's snapshot only when it matches what the house asked for" do
      command = answered("rollback_snapshot", result: good_result)
      snapshot = RemoteRuntime.rollback_snapshot_outcome(command, agent: @agent, generation: @generation)
      assert_kind_of VmMigration::RollbackHome::Snapshot, snapshot
      assert_equal HEX, snapshot.snapshot_id
      assert_equal ROLES.sort, snapshot.shapes.keys.sort
      assert_equal good_result["shapes"], snapshot.shapes

      mismatches = {
        "another resident" => good_result(agent_uuid: SecureRandom.uuid),
        "another container" => good_result(container_name: "someone-else"),
        "another generation" => good_result(generation: @generation + 1),
        "a generation as text" => good_result(generation: @generation.to_s),
        "a short id" => good_result(snapshot_id: "abc"),
        "tools not proved stopped" => good_result(tools_stopped: false),
        "four homes" => good_result(shapes: good_result["shapes"].except("state")),
        "a sixth home" => good_result(shapes: good_result["shapes"].merge("extra" => { "entries" => 1, "shape" => HEX })),
        "a negative count" => good_result(shapes: good_result["shapes"].merge("repo" => { "entries" => -1, "shape" => HEX })),
        "a malformed digest" => good_result(shapes: good_result["shapes"].merge("repo" => { "entries" => 1, "shape" => "XYZ" })),
        "an extra shape field" => good_result(shapes: good_result["shapes"].merge("repo" => { "entries" => 1, "shape" => HEX, "x" => 1 })),
        "no shapes" => good_result(shapes: nil)
      }
      mismatches.each do |label, result|
        command = answered("rollback_snapshot", result:)
        assert_equal :mismatch, RemoteRuntime.rollback_snapshot_outcome(command, agent: @agent, generation: @generation), label
      end
    end

    test "an unanswered snapshot is pending and anything but done is failed" do
      command = RunnerCommand.enqueue!(enrollment: @enrollment, kind: "rollback_snapshot", payload: {})
      assert_equal :pending, RemoteRuntime.rollback_snapshot_outcome(command, agent: @agent, generation: @generation)
      command.deliver!(now: Time.current)
      assert_equal :pending, RemoteRuntime.rollback_snapshot_outcome(command.reload, agent: @agent, generation: @generation)
      %w[failed refused unknown].each do |outcome|
        failed = answered("rollback_snapshot", outcome:, result: good_result)
        assert_equal :failed, RemoteRuntime.rollback_snapshot_outcome(failed, agent: @agent, generation: @generation), outcome
      end
      other = answered("backup_resident", result: good_result)
      assert_equal :failed, RemoteRuntime.rollback_snapshot_outcome(other, agent: @agent, generation: @generation), "another kind's answer"
    end

  end
end
