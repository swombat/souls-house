require "test_helper"

class Api::V1::QuietReasonsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @agent = agents(:research_assistant)
    @user = users(:confirmed_user)
    @chat = @agent.account.chats.create!(title: "Quiet", manual_responses: true, agents: [ @agent ], model_id: "openrouter/auto")
    @token = ApiKey.generate_for(@user, name: "Quiet", agent: @agent).raw_token
    @run = @chat.agent_runtime_interactions.create!(agent: @agent, trigger_kind: "conversation",
      started_at: Time.current, run_id: SecureRandom.uuid, execution_state: "running",
      dispatch_claimed_at: Time.current, execution_deadline_at: 10.minutes.from_now,
      activity_token_expires_at: 20.minutes.from_now)
  end

  test "a resident states a reason for its own live run without posting, waking or handing off" do
    assert_no_difference -> { Message.count } do
      assert_no_difference -> { MessageHandoff.count } do
        assert_no_enqueued_jobs(only: [ AllAgentsResponseJob, ManualAgentResponseJob ]) do
          state_reason("  Mira already answered; nothing to add.  ")
        end
      end
    end

    assert_response :success
    assert_equal "Mira already answered; nothing to add.", response.parsed_body.dig("quiet_reason", "text")
    assert_match(/Shown to everyone in this conversation/, response.parsed_body["visibility"])
    assert_equal "Mira already answered; nothing to add.", @run.reload.quiet_reason
    assert @run.quiet_reason_at
  end

  test "a second statement replaces the first" do
    state_reason("First thought.")
    state_reason("Second thought.")
    assert_response :success
    assert_equal "Second thought.", @run.reload.quiet_reason
  end

  test "a run that already posted a reply cannot state a quiet reason" do
    @chat.messages.create!(role: "assistant", agent: @agent, content: "Replied.", runtime_interaction: @run)
    state_reason("Nothing to say.")
    assert_response :unprocessable_entity
    assert_match(/already posted a reply/, response.parsed_body["error"])
    assert_nil @run.reload.quiet_reason
  end

  test "blank, oversized and NUL reasons are refused" do
    [ "   ", "x" * (AgentRuntimeInteraction::QUIET_REASON_LIMIT + 1), "bad\u0000byte" ].each do |reason|
      state_reason(reason)
      assert_response :unprocessable_entity
    end
    assert_nil @run.reload.quiet_reason
  end

  test "the run must be the resident's own, here, and still live" do
    state_reason("Wrong run", runtime_run_id: SecureRandom.uuid)
    assert_response :not_found

    state_reason("No run", runtime_run_id: "")
    assert_response :unprocessable_entity

    @run.update!(activity_token_expires_at: 1.minute.ago)
    state_reason("Too late")
    assert_response :unprocessable_entity

    @run.update!(activity_token_expires_at: 20.minutes.from_now, agent: agents(:code_reviewer))
    state_reason("Someone else's run")
    assert_response :not_found
    assert_nil @run.reload.quiet_reason
  end

  test "a person's credential cannot state a resident's reason" do
    token = ApiKey.generate_for(@user, name: "Person").raw_token
    post api_v1_conversation_quiet_reason_url(@chat),
      params: { runtime_run_id: @run.run_id, reason: "Speaking for them" },
      headers: { "Authorization" => "Bearer #{token}" }
    assert_response :forbidden
    assert_nil @run.reload.quiet_reason
  end

  private

  def state_reason(reason, **options)
    post api_v1_conversation_quiet_reason_url(@chat),
      params: { reason: reason, runtime_run_id: @run.run_id }.merge(options),
      headers: { "Authorization" => "Bearer #{@token}" }
  end

end
