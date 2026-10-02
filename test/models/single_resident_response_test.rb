require "test_helper"

class SingleResidentResponseTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @account = @user.personal_account
    @resident = @account.agents.create!(name: "Solo", system_prompt: "Test", runtime: "external")
    @chat = @account.chats.new(title: "Solo room", manual_responses: true)
    @chat.agents = [ @resident ]
    @chat.save!
  end

  test "human message wakes the only resident without a mention" do
    assert_enqueued_jobs 1, only: ManualAgentResponseJob do
      message = post_human
      assert message.single_resident_response_triggered
      run = @chat.agent_runtime_interactions.sole
      assert_equal "queued", run.execution_state
      assert_equal @resident, run.agent
      assert @chat.agent_response_active?(@resident)
    end
  end

  test "opening message also wakes the only resident" do
    assert_enqueued_jobs 1, only: [ AllAgentsResponseJob, ManualAgentResponseJob ] do
      Chat.create_with_message!({ account: @account, title: "New room", manual_responses: true },
        message_content: "Hello", user: @user, agent_ids: [ @resident.id ])
    end
  end

  test "resident replies and anonymous or system messages never self-trigger" do
    assert_no_enqueued_jobs only: [ AllAgentsResponseJob, ManualAgentResponseJob ] do
      @chat.messages.create!(role: "assistant", agent: @resident, content: "Reply")
      @chat.messages.create!(role: "user", content: "Anonymous")
      @chat.messages.create!(role: "system", content: "System")
    end
  end

  test "multiple residents do not automatically trigger even if only one is available" do
    @chat.agents << @account.agents.create!(name: "Other", system_prompt: "Test", runtime: "offline", active: false)
    assert_no_enqueued_jobs(only: [ AllAgentsResponseJob, ManualAgentResponseJob ]) { post_human }
  end

  test "unavailable resident is not triggered" do
    @resident.update!(active: false)
    assert_no_enqueued_jobs(only: [ AllAgentsResponseJob, ManualAgentResponseJob ]) { post_human }
  end

  test "archived rooms do not trigger" do
    @chat.update!(archived_at: Time.current)
    assert_no_enqueued_jobs(only: [ AllAgentsResponseJob, ManualAgentResponseJob ]) { post_human }
  end

  test "already responding resident is not started again" do
    AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat)
    assert_no_enqueued_jobs(only: [ AllAgentsResponseJob, ManualAgentResponseJob ]) { post_human }
  end

  test "a second message while queued does not reserve another wake" do
    post_human
    assert_no_difference "AgentRuntimeInteraction.count" do
      @chat.messages.create!(role: "user", user: @user, content: "One more thought")
    end
  end

  test "attachment-only opening messages wake the resident" do
    assert_enqueued_jobs 1, only: [ AllAgentsResponseJob, ManualAgentResponseJob ] do
      Chat.create_with_message!({ account: @account, title: "File room", manual_responses: true },
        user: @user, agent_ids: [ @resident.id ],
        files: [ { io: StringIO.new("attachment"), filename: "note.txt", content_type: "text/plain" } ])
    end
  end

  test "edits do not wake the resident again" do
    message = post_human
    assert_no_enqueued_jobs(only: [ AllAgentsResponseJob, ManualAgentResponseJob ]) { message.update!(content: "Edited") }
  end

  test "rolled back messages never wake a resident" do
    assert_no_enqueued_jobs only: [ AllAgentsResponseJob, ManualAgentResponseJob ] do
      Message.transaction(requires_new: true) do
        post_human
        raise ActiveRecord::Rollback
      end
    end
  end

  test "missing credentials preserve the hello without dispatch or runtime work" do
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: nil)
    assert_no_difference [ "MessageDispatch.count", "AgentRuntimeInteraction.count" ] do
      assert_no_enqueued_jobs only: [ AllAgentsResponseJob, ManualAgentResponseJob ] do
        message = post_human
        assert message.persisted?
        assert_not message.single_resident_response_triggered
      end
    end
    assert_equal Agents::InferenceAvailability::MISSING_CREDENTIALS_MESSAGE, @resident.inference_setup_message
    assert_equal @resident.inference_setup_message, @resident.as_json(as: :list)["inference_setup_message"]
  end

  test "missing credentials also block the direct fallback" do
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: nil)
    AgentRuntimeInteraction.stub :live_activity_enabled?, false do
      assert_no_enqueued_jobs(only: [ AllAgentsResponseJob, ManualAgentResponseJob ]) { post_human }
    end
  end

  test "configured credentials clear the setup notice and allow the next hello" do
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: "test-only-router")
    assert_nil @resident.inference_setup_message
    assert_enqueued_jobs(1, only: ManualAgentResponseJob) { post_human }
  end

  test "an unfunded house route does not automatically wake" do
    @resident.update!(model_id: HouseInference::Offering::MODEL_ID)
    assert_no_enqueued_jobs(only: [ AllAgentsResponseJob, ManualAgentResponseJob ]) { post_human }
    assert_match "allowance", @resident.inference_setup_message
  end

  test "a funded house model wakes without personal credentials" do
    @account.update!(use_system_ai_credentials: false)
    @resident.update!(model_id: HouseInference::Offering::MODEL_ID)
    HouseInferenceGrant.create!(agent: @resident, user: @user)
    HouseInference::Offering.stub :configured?, true do
      assert_nil @resident.inference_setup_message
      assert_enqueued_jobs(1, only: ManualAgentResponseJob) { post_human }
    end
  end

  test "a connected OAuth resident wakes without an API key" do
    @account.update!(use_system_ai_credentials: false)
    @resident.update!(model_id: "openai/gpt-6-sol", provider_auth_modes: { openai: "oauth_account" },
      provider_connections: { openai: { status: "connected" } })
    assert_nil @resident.inference_setup_message
    assert_enqueued_jobs(1, only: ManualAgentResponseJob) { post_human }
  end

  test "a pending house call is not a setup failure and another conversation can queue" do
    @account.update!(use_system_ai_credentials: false)
    @resident.update!(model_id: HouseInference::Offering::MODEL_ID)
    grant = HouseInferenceGrant.create!(agent: @resident, user: @user)
    grant.house_inference_calls.create!(month: HouseInference::Offering.month,
      model_id: @resident.model_id, provider_route: "fireworks/us", charge_usd: 0.75)
    HouseInference::Offering.stub :configured?, true do
      assert_equal "house_inference_busy", Agents::InferenceAvailability.house_error(@resident).code
      assert_nil @resident.inference_setup_message
      assert_enqueued_jobs(1, only: ManualAgentResponseJob) { post_human }
    end
  end

  private

  def post_human
    @chat.messages.create!(role: "user", user: @user, content: "Hello resident")
  end

end
