require "test_helper"

class AgentRuntimeInteraction::FailureReportTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(runtime: "external", uuid: SecureRandom.uuid_v7, endpoint_url: "https://agent.example.com", trigger_bearer_token: "tr_valid")
    @chat = @agent.account.chats.create!(title: "Failures", manual_responses: true, agents: [ @agent ])
  end

  test "only failed and timed-out runs are failures; busy, lost, cancelled and unfinished runs are neither" do
    assert_equal :failure, live_run("failed").streak_outcome
    assert_equal :failure, live_run("timed_out").streak_outcome
    assert_equal :success, live_run("completed").streak_outcome
    %w[busy outcome_unknown cancelled running queued].each do |state|
      assert_equal :neutral, live_run(state).streak_outcome, state
    end
  end

  test "runs without live activity are read from the result they stored" do
    assert_equal :failure, plain_run(runtime_status: "error", runtime_returncode: 1).streak_outcome
    assert_equal :failure, plain_run(runtime_status: "timeout").streak_outcome
    assert_equal :failure, plain_run(error_class: "Errno::ECONNREFUSED", error_message: "refused").streak_outcome
    assert_equal :success, plain_run(runtime_status: "ok", runtime_returncode: 0).streak_outcome
    assert_equal :neutral, plain_run(runtime_status: "already_running", transport_status: 409).streak_outcome
    assert_equal :neutral, plain_run(runtime_status: "ok", finished_at: nil).streak_outcome
  end

  test "the category comes from structured fields only, never from log text" do
    assert_equal "timed_out", live_run("timed_out").failure_category
    assert_equal "runtime_unavailable", live_run("failed", error_class: "Errno::ECONNREFUSED", error_message: "x").failure_category
    assert_equal "runtime_unavailable", live_run("failed", error_class: "Net::OpenTimeout").failure_category
    assert_equal "runtime_unavailable", plain_run(transport_status: 502).failure_category
    assert_equal "runtime_error", live_run("failed", runtime_status: "error", runtime_returncode: 1).failure_category
    assert_equal "unknown", live_run("failed").failure_category
    # Text that looks like a cause is not evidence of one.
    assert_equal "unknown", live_run("failed", stderr: "connection refused: provider 429", error_message: "timeout").failure_category
    assert_nil live_run("completed").failure_category
    assert_nil live_run("busy").failure_category
  end

  private

  def live_run(state, **attrs)
    finished = state.in?(AgentRuntimeInteraction::TERMINAL_STATES) ? 1.minute.ago : nil
    AgentRuntimeInteraction.create!(
      agent: @agent, chat: @chat, trigger_kind: "conversation", requested_by: "souls.house",
      session_id: "s", started_at: 2.minutes.ago, run_id: SecureRandom.uuid,
      execution_state: state, finished_at: finished, **attrs
    )
  end

  def plain_run(**attrs)
    AgentRuntimeInteraction.create!(
      agent: @agent, chat: @chat, trigger_kind: "conversation", requested_by: "souls.house",
      session_id: "s", started_at: 2.minutes.ago, finished_at: 1.minute.ago, **attrs
    )
  end

end
