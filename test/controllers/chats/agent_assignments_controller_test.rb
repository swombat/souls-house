require "test_helper"

class Chats::AgentAssignmentsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chat = @account.chats.create!(
      model_id: "openrouter/auto",
      title: "Test Conversation"
    )
    @agent = @account.agents.create!(name: "Test Agent", system_prompt: "You are a test agent", runtime: "external")

    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path
  end

  test "create assigns agent to chat" do
    assert_not @chat.manual_responses?

    post account_chat_agent_assignment_path(@account, @chat), params: { agent_id: @agent.to_param }

    assert_redirected_to account_chat_path(@account, @chat)
    @chat.reload
    assert @chat.manual_responses?
    assert_includes @chat.agents, @agent
  end

  test "create rejects assignment when chat already has agent" do
    # Create a group chat that already has manual_responses enabled with an agent
    group_chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    group_chat.agent_ids = [ @agent.id ]
    group_chat.save!

    post account_chat_agent_assignment_path(@account, group_chat), params: { agent_id: @agent.to_param }

    assert_redirected_to account_chat_path(@account, group_chat)
    assert_match(/already assigned/, flash[:alert])
  end

  test "create creates system message" do
    assert_difference "Message.count" do
      post account_chat_agent_assignment_path(@account, @chat), params: { agent_id: @agent.to_param }
    end

    system_message = @chat.messages.last
    assert_match(/now being handled by #{@agent.name}/, system_message.content)
  end

  test "create creates audit log" do
    assert_difference "AuditLog.count" do
      post account_chat_agent_assignment_path(@account, @chat), params: { agent_id: @agent.to_param }
    end

    audit = AuditLog.last
    assert_equal "assign_agent_to_chat", audit.action
  end

end
