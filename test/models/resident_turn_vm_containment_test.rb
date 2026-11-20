require "test_helper"

# #1056: closing an unknown turn for a resident on its own server must close
# the VM's ledger too, or fail and keep the house's reservation. Before this,
# resolve_turn was a fixed 501 and an operator's house-side fix left the VM
# refusing every later turn with "session already reserved".
class ResidentTurnVmContainmentTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4242)
    @enrollment, token = RunnerEnrollment.mint!(placement:)
    @enrollment.confirm_provider_server!(4242)
    @enrollment.enroll!(token:, public_key: Base64.strict_encode64("k" * 32), reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
    @run = AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake", session_id: "s",
      started_at: Time.current, endpoint_url: "runner://#{@enrollment.public_id}")
    @turn = ResidentTurn.create!(agent: @agent, agent_runtime_interaction: @run, dispatch_id: SecureRandom.uuid,
      session_id: "s", payload: "{}", state: "unknown", ledger_id: SecureRandom.uuid)
    @now = Time.current
  end

  # A fake runner: answers each open command by kind when the client sleeps.
  def client(answers)
    sleeper = lambda do |seconds|
      @now += seconds
      command = RunnerCommand.where.not(state: RunnerCommand::TERMINAL).order(:id).first
      next unless command

      command.deliver!(now: @now) if command.state == "queued"
      command.record_result!(answers.fetch(command.kind).call(command), now: @now)
    end
    RemoteTriggerClient.new(enrollment: @enrollment, agent: @agent, resident_turn: @turn, sleeper:, clock: -> { @now })
  end

  def relayed(status, body) = ->(_c) { { "outcome" => "done", "result" => { "status" => status, "body" => body } } }

  def resolve!(answers)
    @turn.resolve_after_containment!(operator: users(:site_admin_user), reason: "Verified the VM container stopped", client: client(answers))
  end

  test "a VM resident's turn is reached through its runner, not a trigger URL" do
    relay = Object.new
    Agents::RemoteRuntime.stub(:client_for, ->(turn) { turn == @turn ? relay : flunk("wrong turn") }) do
      ChaosTriggerClient.stub(:new, ->(*) { flunk("a runner:// endpoint was given an HTTP client") }) do
        assert_same relay, @turn.trigger_client
      end
    end
  end

  test "an unknown VM turn is resolved on the VM's ledger, then closed on the house's" do
    seen = nil
    resolve!(
      "turn_status" => relayed(200, { "id" => @turn.dispatch_id, "state" => "unknown" }),
      "resolve_turn" => lambda { |command|
        seen = command.envelope.fetch("payload")
        { "outcome" => "done", "result" => { "status" => 200, "body" => { "state" => "cancelled" } } }
      }
    )
    assert_equal({ "execution_stopped" => true }, seen.fetch("body"))
    assert_equal @turn.dispatch_id, seen.fetch("dispatch_id")
    assert_nil seen["ledger_id"]
    assert_equal "cancelled", @turn.reload.state
    assert @turn.finished_at?
  end

  test "a runner that predates resolve refuses it, and the house keeps its reservation" do
    error = assert_raises(RuntimeError) do
      resolve!(
        "turn_status" => relayed(200, { "id" => @turn.dispatch_id, "state" => "unknown" }),
        "resolve_turn" => ->(_c) { { "outcome" => "refused", "error" => "command not allowed on this runner: 'resolve_turn'" } }
      )
    end
    assert_match "did not acknowledge containment", error.message
    assert_equal "unknown", @turn.reload.state
    assert_not @turn.finished_at?
  end

  test "a VM turn still running is not resolved on either side" do
    assert_raises(RuntimeError) do
      resolve!("turn_status" => relayed(200, { "id" => @turn.dispatch_id, "state" => "running" }))
    end
    assert_equal 0, RunnerCommand.where(kind: "resolve_turn").count
    assert_equal "unknown", @turn.reload.state
  end

end
