require "test_helper"

class Chats::AgentTriggersControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = @account.agents.create!(name: "Test Agent", system_prompt: "You are a test agent", runtime: "external")
    @chat = create_group_chat(@account, agent_ids: [ @agent.id ])

    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path
  end

  test "create triggers specific agent when agent_id provided" do
    assert_enqueued_with(job: ManualAgentResponseJob, args: [ @chat, @agent ]) do
      post account_chat_agent_trigger_path(@account, @chat),
        params: { agent_id: @agent.to_param },
        as: :json
    end

    assert_response :success
  end

  test "create triggers all agents when no agent_id provided" do
    post account_chat_agent_trigger_path(@account, @chat), as: :json

    assert_response :success
  end

  test "rejects a specific agent trigger while that agent is already responding" do
    @chat.agent_runtime_interactions.create!(
      agent: @agent,
      trigger_kind: "conversation",
      started_at: 1.minute.ago
    )

    assert_no_enqueued_jobs only: ManualAgentResponseJob do
      post account_chat_agent_trigger_path(@account, @chat),
        params: { agent_id: @agent.to_param },
        as: :json
    end

    assert_response :unprocessable_entity
    assert_equal "#{@agent.name} is already responding", response.parsed_body["error"]
  end

  test "allows a specific agent trigger when an unfinished interaction is stale" do
    @chat.agent_runtime_interactions.create!(
      agent: @agent,
      trigger_kind: "conversation",
      started_at: AgentRuntimeInteraction::ACTIVE_WINDOW.ago - 1.minute
    )

    assert_enqueued_with(job: ManualAgentResponseJob, args: [ @chat, @agent ]) do
      post account_chat_agent_trigger_path(@account, @chat),
        params: { agent_id: @agent.to_param },
        as: :json
    end

    assert_response :success
  end

  test "rejects ask all while one agent is already responding" do
    @chat.agent_runtime_interactions.create!(
      agent: @agent,
      trigger_kind: "conversation",
      started_at: 1.minute.ago
    )

    assert_no_enqueued_jobs only: AllAgentsResponseJob do
      post account_chat_agent_trigger_path(@account, @chat), as: :json
    end

    assert_response :unprocessable_entity
    assert_equal "#{@agent.name} is already responding", response.parsed_body["error"]
  end

  test "requires authentication" do
    delete logout_path

    post account_chat_agent_trigger_path(@account, @chat), as: :json
    assert_response :redirect
  end

  test "scopes to current account" do
    other_user = User.create!(email_address: "triggerother@example.com")
    other_user.profile.update!(first_name: "Other", last_name: "User")
    other_account = other_user.personal_account
    other_chat = other_account.chats.create!(model_id: "openrouter/auto")

    post account_chat_agent_trigger_path(@account, other_chat), as: :json
    assert_response :not_found
  end

  private

  def create_group_chat(account, agent_ids:)
    chat = account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    chat.agent_ids = agent_ids
    chat.save!
    chat
  end

end
