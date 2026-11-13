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

  test "a model the subscription doesn't offer is its own category, from the runtime's structured kind" do
    refused = live_run("failed", runtime_status: "error", runtime_returncode: 1,
      response_body: { "status" => "error", "error_kind" => "model_unavailable" })
    assert_equal "model_unavailable", refused.failure_category
    # The CLI's words in stdout are not the evidence; the runtime's classification is.
    assert_equal "runtime_error", live_run("failed", runtime_status: "error", runtime_returncode: 1,
      stdout: "model gemini-4-argon-medium is not recognized as a known model").failure_category
  end

  test "the card says why when every failure in the streak was a refused model" do
    2.times do
      live_run("failed", runtime_status: "error", runtime_returncode: 1,
        response_body: { "status" => "error", "error_kind" => "model_unavailable" })
    end
    card = Agents::RunFailureStreak.call(@agent).as_card_json
    assert_equal 2, card[:count]
    assert card[:model_unavailable]
    assert_not card[:runtime_unavailable]
  end

  test "a house allowance refusal recorded on the run is the run's category, even if the runtime then hung" do
    spent = live_run("failed", runtime_status: "error", runtime_returncode: 1, inference_refusal: "house_allowance_exhausted")
    assert_equal "house_allowance_exhausted", spent.failure_category
    assert_equal "its house allowance is used up for this month", spent.failure_reason
    assert_equal "house_allowance_none", live_run("timed_out", inference_refusal: "house_allowance_none").failure_category
    # A refusal on a run that went on to complete is not a failure.
    assert_nil live_run("completed", inference_refusal: "house_allowance_exhausted").failure_category
    # Absent evidence stays what the other fields say.
    assert_equal "runtime_error", live_run("failed", runtime_status: "error", runtime_returncode: 1).failure_category
    assert_equal "unknown", live_run("failed", inference_refusal: "something_else").failure_category
  end

  test "the house's provider refusing a call is the house's category, not a setup one" do
    refused = live_run("failed", runtime_status: "error", runtime_returncode: 1, inference_refusal: "house_provider_refused")
    assert_equal "house_provider_refused", refused.failure_category
    assert_equal "the house's model provider refused a request it made", refused.failure_reason
    2.times { live_run("failed", inference_refusal: "house_provider_refused") }
    assert_not Agents::RunFailureStreak.call(@agent).as_card_json[:needs_setup]
  end

  test "a scheduled run refused before dispatch for its house allowance says which allowance" do
    refusal = { "status" => "error", "error_kind" => "needs_setup", "error" => "The $10 house allowance is used up." }
    assert_equal "house_allowance_exhausted",
      live_run("failed", response_body: refusal.merge("refusal_code" => "house_allowance_exhausted")).failure_category
    assert_equal "needs_setup", live_run("failed", response_body: refusal).failure_category
    assert_equal "needs_setup", live_run("failed", response_body: refusal.merge("refusal_code" => "house_inference_busy")).failure_category
  end

  test "a runtime error says what the runtime said, without changing the category or the error fields" do
    failure = { "code" => "antigravity_runtime_failed", "message" => "Antigravity invocation failed with status ERROR; last step 7: tool ERROR" }
    run = live_run("failed", runtime_status: "error", runtime_returncode: 1,
      response_body: { "status" => "error", "runtime_failure" => failure })
    assert_equal "runtime_error", run.failure_category
    assert_equal "the run ended in an error (runtime said: antigravity_runtime_failed: " \
      "Antigravity invocation failed with status ERROR; last step 7: tool ERROR)", run.failure_reason
    assert_nil run.error_class
    # Without the field, the reason is the category alone, as before.
    assert_equal "the run ended in an error",
      live_run("failed", runtime_status: "error", runtime_returncode: 1, stdout: "status ERROR").failure_reason
    # Only a runtime error carries it.
    limited = live_run("failed", runtime_status: "error", runtime_returncode: 1,
      response_body: { "status" => "error", "error_kind" => "subscription_limit", "runtime_failure" => failure })
    assert_equal "the run's output looked like its subscription's usage limit", limited.failure_reason
  end

  test "a provider-edge kind is its own category, read ahead of authentication, and its reason says what the runtime said" do
    said = { "code" => "clamp_runtime_failed",
             "message" => "Claude Code reported a failed result: Failed to authenticate. API Error: 403 Attention Required! | Cloudflare" }
    challenge = live_run("failed", runtime_status: "error", runtime_returncode: 1,
      response_body: { "status" => "error", "error_kind" => "provider_challenge", "runtime_failure" => said })
    assert_equal "provider_challenge", challenge.failure_category
    assert_includes challenge.failure_reason, "403"
    assert_includes challenge.failure_reason, "Cloudflare"
    overloaded = live_run("failed", runtime_status: "error", runtime_returncode: 1,
      response_body: { "status" => "error", "error_kind" => "provider_transient" })
    assert_equal "provider_transient", overloaded.failure_category
    assert_equal "its model provider answered with a server error or an overload", overloaded.failure_reason
    # A kind the house doesn't know stays out of the category.
    stray = live_run("failed", runtime_status: "error", runtime_returncode: 1,
      response_body: { "status" => "error", "error_kind" => "provider_whatever" })
    assert_equal "runtime_error", stray.failure_category
  end

  test "the runtime's subscription-limit kind is its own category" do
    limited = live_run("failed", runtime_status: "error", runtime_returncode: 1,
      response_body: { "status" => "error", "error_kind" => "subscription_limit" })
    assert_equal "subscription_limit", limited.failure_category
    assert_equal "the run's output looked like its subscription's usage limit", limited.failure_reason
    assert_nil live_run("completed").failure_reason
  end

  test "allowance refusals count as setup on the card; a mixed streak does not" do
    2.times { live_run("failed", inference_refusal: "house_allowance_exhausted") }
    assert Agents::RunFailureStreak.call(@agent).as_card_json[:needs_setup]
    live_run("failed", runtime_status: "error", runtime_returncode: 1)
    assert_not Agents::RunFailureStreak.call(@agent).as_card_json[:needs_setup]
  end

  test "the card names the cause only when every failure in a complete streak shares an informative one" do
    2.times { live_run("failed", inference_refusal: "house_provider_refused") }
    assert_equal "the house's model provider refused a request it made", Agents::RunFailureStreak.call(@agent).as_card_json[:cause]
    live_run("failed", response_body: { "status" => "error", "error_kind" => "subscription_limit" })
    assert_nil Agents::RunFailureStreak.call(@agent).as_card_json[:cause], "mixed causes name none"
  end

  test "a streak of plain runtime errors gets no cause line on the card" do
    2.times { live_run("failed", runtime_status: "error", runtime_returncode: 1) }
    assert_nil Agents::RunFailureStreak.call(@agent).as_card_json[:cause]
  end

  test "every category has a cause line" do
    assert_equal AgentRuntimeInteraction::FailureReport::FAILURE_CATEGORIES.sort, RunFailureNotice::NO_REPLY_CAUSES.keys.sort
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
