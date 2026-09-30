require "test_helper"

class ResidentTurnTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    Setting.instance.update!(resident_turn_limit: 2)
  end

  def queue_turn(agent: @agent, session: SecureRandom.uuid)
    interaction = AgentRuntimeInteraction.create!(
      agent: agent, trigger_kind: "wake", session_id: session,
      started_at: Time.current, endpoint_url: "https://runtime.example.test"
    )
    ResidentTurn.enqueue!(interaction, { session_id: session, request: "private prompt" })
  end

  test "admission is bounded and uncertain executions continue occupying capacity" do
    first, second, third = 3.times.map { queue_turn }
    assert_equal [ first.id, second.id ], ResidentTurn.admit!
    first.update!(state: "unknown")
    assert_empty ResidentTurn.admit!
    assert_equal "queued", third.reload.state
  end

  test "admission shares slots between residents before admitting their next turn" do
    first = queue_turn
    second = queue_turn
    other = queue_turn(agent: agents(:other_account_agent))
    assert_equal [ first.id, other.id ], ResidentTurn.admit!
    assert_equal "queued", second.reload.state
  end

  test "pause prevents admission without cancelling work" do
    turn = queue_turn
    Setting.instance.update!(resident_turn_limit: 0)
    assert_empty ResidentTurn.admit!
    assert_equal "queued", turn.reload.state
  end

  test "duplicate pending session is rejected rather than replaying stale Telegram context" do
    queue_turn(session: "one-session")
    assert_raises(ResidentTurn::SessionBusy) { queue_turn(session: "one-session") }
  end

  test "prompt is encrypted and queued cancellation releases without HTTP" do
    turn = queue_turn
    assert_not_includes turn.ciphertext_for(:payload), "private prompt"
    turn.cancel!
    assert_equal "cancelled", turn.reload.state
    assert turn.finished_at?
    assert_equal "{}", turn.payload
  end

  test "running cancellation retains capacity until process exit is confirmed" do
    turn = queue_turn
    ResidentTurn.admit!
    turn.reload.cancel!
    assert_equal 1, ResidentTurn.occupying_capacity.count
    assert_nil turn.reload.finished_at
    turn.finish!({ "status" => 504, "body" => { "status" => "timeout" } }, cancelled: true)
    assert_equal 0, ResidentTurn.occupying_capacity.count
    assert_equal "cancelled", turn.reload.state
  end

  test "acceptance does not mark legacy interaction completed" do
    turn = queue_turn
    interaction = turn.agent_runtime_interaction
    interaction.record_result!({ status: 202, body: { "status" => "queued" } })
    assert_nil interaction.reload.finished_at
  end

  test "containment resolution preserves accounting received before supervisor loss" do
    turn = queue_turn
    turn.agent_runtime_interaction.record_result!({ status: 200, body: {
      "status" => "ok", "usage" => { "input_tokens" => 123 }
    } })
    turn.finish!({ "status" => 409, "body" => { "status" => "cancelled" } }, cancelled: true)
    assert_equal 123, turn.agent_runtime_interaction.reload.input_tokens
    assert_equal "ok", turn.agent_runtime_interaction.runtime_status
  end

  test "a producer error after durable handoff cannot finish the interaction" do
    turn = queue_turn
    interaction = turn.agent_runtime_interaction
    interaction.record_error!(RuntimeError.new("synthetic enqueue acknowledgement failure"))
    assert_nil interaction.reload.finished_at
    turn.finish!({ "status" => 200, "body" => { "status" => "ok" } })
    assert_nil interaction.reload.error_message
    assert interaction.finished_at?
  end

end
