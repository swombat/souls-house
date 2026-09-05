require "test_helper"

class Chats::ParticipantsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)

    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path
  end

  test "create adds agent to group chat and creates system message" do
    agent1 = @account.agents.create!(name: "Agent One", system_prompt: "You are agent one")
    agent2 = @account.agents.create!(name: "Agent Two", system_prompt: "You are agent two", runtime: "external")

    group_chat = create_group_chat(@account, agent_ids: [ agent1.id ])
    assert group_chat.group_chat?

    assert_difference "Message.count", 1 do
      post account_chat_participant_path(@account, group_chat), params: { agent_id: agent2.to_param }
    end

    assert_redirected_to account_chat_path(@account, group_chat)
    group_chat.reload
    assert_includes group_chat.agents, agent2

    system_message = group_chat.messages.last
    assert_equal "user", system_message.role
    assert_match(/Agent Two has joined the conversation/, system_message.content)
  end

  test "create rejected for non-group chat" do
    chat = @account.chats.create!(model_id: "openrouter/auto", title: "Regular Chat")
    assert_not chat.group_chat?

    agent = @account.agents.create!(name: "Test Agent", system_prompt: "You are a test agent")

    post account_chat_participant_path(@account, chat), params: { agent_id: agent.to_param }

    assert_redirected_to account_chat_path(@account, chat)
    assert_match(/group chats/, flash[:alert])
  end

  test "create rejected for duplicate agent" do
    agent = @account.agents.create!(name: "Agent One", system_prompt: "You are agent one", runtime: "external")

    group_chat = create_group_chat(@account, agent_ids: [ agent.id ])

    assert_no_difference "Message.count" do
      post account_chat_participant_path(@account, group_chat), params: { agent_id: agent.to_param }
    end

    assert_redirected_to account_chat_path(@account, group_chat)
    assert_match(/already in this conversation/, flash[:alert])
  end

  test "create adds agent to chat agents association" do
    agent1 = @account.agents.create!(name: "Agent One", system_prompt: "You are agent one")
    agent2 = @account.agents.create!(name: "Agent Two", system_prompt: "You are agent two", runtime: "external")

    group_chat = create_group_chat(@account, agent_ids: [ agent1.id ])
    assert_equal 1, group_chat.agents.count

    post account_chat_participant_path(@account, group_chat), params: { agent_id: agent2.to_param }

    group_chat.reload
    assert_equal 2, group_chat.agents.count
    assert_includes group_chat.agents, agent1
    assert_includes group_chat.agents, agent2
  end

  private

  def create_group_chat(account, agent_ids:)
    chat = account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    chat.agent_ids = agent_ids
    chat.save!
    chat
  end

end
