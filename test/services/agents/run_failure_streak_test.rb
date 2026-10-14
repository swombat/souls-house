require "test_helper"

class Agents::RunFailureStreakTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(runtime: "external", uuid: SecureRandom.uuid_v7, endpoint_url: "https://agent.example.com", trigger_bearer_token: "tr_valid")
    @chat = @agent.account.chats.create!(title: "Streak", manual_responses: true, agents: [ @agent ])
  end

  test "counts consecutive failures back to the last completed run, and says when the streak began" do
    make_run("completed", at: 50.minutes.ago)
    first = make_run("failed", at: 40.minutes.ago)
    make_run("timed_out", at: 30.minutes.ago)
    make_run("failed", at: 20.minutes.ago)

    streak = Agents::RunFailureStreak.call(@agent)
    assert_equal 3, streak.count
    assert_equal first.started_at.to_i, streak.since.to_i
  end

  test "a completed run resets the streak" do
    make_run("failed", at: 40.minutes.ago)
    make_run("failed", at: 30.minutes.ago)
    make_run("completed", at: 20.minutes.ago)

    assert_equal 0, Agents::RunFailureStreak.call(@agent).count
  end

  test "busy and lost runs neither count nor reset" do
    make_run("failed", at: 40.minutes.ago)
    make_run("busy", at: 35.minutes.ago)
    make_run("outcome_unknown", at: 30.minutes.ago)
    make_run("failed", at: 20.minutes.ago)
    plain_busy(at: 10.minutes.ago)

    assert_equal 2, Agents::RunFailureStreak.call(@agent).count
  end

  test "only conversation runs count, and through: reads the streak as it stood at that run" do
    make_run("failed", at: 40.minutes.ago)
    middle = make_run("failed", at: 30.minutes.ago)
    make_run("failed", at: 20.minutes.ago, trigger_kind: "wake")
    make_run("failed", at: 10.minutes.ago)

    assert_equal 3, Agents::RunFailureStreak.call(@agent).count
    assert_equal 2, Agents::RunFailureStreak.call(@agent, through: middle).count
  end

  test "the runtime is called not starting only when every failure in the streak says so" do
    make_run("failed", at: 30.minutes.ago, error_class: "Errno::ECONNREFUSED")
    make_run("failed", at: 20.minutes.ago, error_class: "Errno::ECONNREFUSED")
    assert Agents::RunFailureStreak.call(@agent).runtime_unavailable?

    make_run("failed", at: 10.minutes.ago, runtime_status: "error", runtime_returncode: 1)
    assert_not Agents::RunFailureStreak.call(@agent).runtime_unavailable?
  end

  private

  def make_run(state, at:, trigger_kind: "conversation", **attrs)
    AgentRuntimeInteraction.create!(
      agent: @agent, chat: @chat, trigger_kind: trigger_kind, requested_by: "souls.house",
      session_id: "s", started_at: at - 1.minute, run_id: SecureRandom.uuid,
      execution_state: state, finished_at: at, **attrs
    )
  end

  def plain_busy(at:)
    AgentRuntimeInteraction.create!(
      agent: @agent, chat: @chat, trigger_kind: "conversation", requested_by: "souls.house",
      session_id: "s", started_at: at - 1.minute, finished_at: at,
      runtime_status: "already_running", transport_status: 409
    )
  end

end
