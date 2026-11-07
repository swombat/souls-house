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

  test "destroy removes last seat, preserves history and audits" do
    agent = agents(:research_assistant)
    chat = create_group_chat(@account, agent_ids: [ agent.id ])
    past = chat.messages.create!(role: "assistant", agent: agent, content: "Keep this reply")

    assert_difference "AuditLog.where(action: 'remove_agent_from_chat').count", 1 do
      delete account_chat_participant_path(@account, chat), params: { agent_id: agent.to_param }
    end
    assert_redirected_to account_chat_path(@account, chat)
    assert_empty chat.agents.reload
    assert_equal agent, past.reload.agent
    assert_equal "[System Notice] #{agent.name} has left the conversation.", chat.messages.last.content
    assert chat.reload.valid?
  end

  test "destroy refuses an admitted response without cancelling it" do
    agent = agents(:research_assistant)
    chat = create_group_chat(@account, agent_ids: [ agent.id ])
    run = AgentRuntimeInteraction.reserve!(agent: agent, chat: chat)

    assert_no_difference "Message.count" do
      delete account_chat_participant_path(@account, chat), params: { agent_id: agent.to_param }
    end
    assert_redirected_to account_chat_path(@account, chat)
    assert_match(/already responding/, flash[:alert])
    assert chat.agents.exists?(agent.id)
    assert_nil run.reload.finished_at
  end

  test "destroy cannot remove an agent outside the chat" do
    chat = create_group_chat(@account, agent_ids: [ agents(:research_assistant).id ])
    delete account_chat_participant_path(@account, chat), params: { agent_id: agents(:code_reviewer).to_param }
    assert_response :not_found
  end

  test "update sets the seated residents from the ticked list" do
    stay = agents(:research_assistant)
    leave = agents(:code_reviewer)
    join = @account.agents.create!(name: "Joiner", system_prompt: "You join", runtime: "external")
    chat = create_group_chat(@account, agent_ids: [ stay.id, leave.id ])

    patch account_chat_participant_path(@account, chat), params: { agent_ids: [ stay.to_param, join.to_param ] }

    assert_redirected_to account_chat_path(@account, chat)
    assert_nil flash[:alert]
    assert_equal [ join.id, stay.id ].sort, chat.agents.reload.pluck(:id).sort
    notices = chat.messages.order(:id).last(2).map(&:content)
    assert_includes notices, "[System Notice] Joiner has joined the conversation."
    assert_includes notices, "[System Notice] #{leave.name} has left the conversation."
  end

  test "update keeps a responding resident, names it, and applies the rest" do
    busy = agents(:research_assistant)
    other = agents(:code_reviewer)
    chat = create_group_chat(@account, agent_ids: [ busy.id, other.id ])
    AgentRuntimeInteraction.reserve!(agent: busy, chat: chat)

    patch account_chat_participant_path(@account, chat), params: { agent_ids: [] }, as: :json

    assert_match(/#{busy.name} is already responding/, flash[:alert])
    assert_equal [ busy.id ], chat.agents.reload.pluck(:id)
  end

  test "update refuses a resident from outside the account" do
    chat = create_group_chat(@account, agent_ids: [ agents(:research_assistant).id ])
    stranger = Account.where.not(id: @account.id).first.agents.create!(name: "Stranger", system_prompt: "x")

    patch account_chat_participant_path(@account, chat),
      params: { agent_ids: [ agents(:research_assistant).to_param, stranger.to_param ] }

    assert_match(/no longer available/, flash[:alert])
    assert_not chat.agents.reload.exists?(stranger.id)
  end

  test "update with an explicit empty list removes every removable seat" do
    chat = create_group_chat(@account, agent_ids: [ agents(:research_assistant).id, agents(:code_reviewer).id ])

    patch account_chat_participant_path(@account, chat), params: { agent_ids: [] }, as: :json

    assert_redirected_to account_chat_path(@account, chat)
    assert_empty chat.agents.reload
  end

  test "update rejects malformed agent_ids before changing anything" do
    chat = create_group_chat(@account, agent_ids: [ agents(:research_assistant).id, agents(:code_reviewer).id ])
    keep = agents(:research_assistant).to_param

    [ nil, false, "x", { "a" => keep }, [ nil ], [ false ], [ 1 ], [ "" ], [ keep, nil ], [ [ keep ] ] ].each do |bad|
      assert_no_difference -> { chat.messages.count } do
        patch account_chat_participant_path(@account, chat), params: { agent_ids: bad }, as: :json
      end
      assert_response :bad_request, "accepted #{bad.inspect}"
    end

    patch account_chat_participant_path(@account, chat), params: { other: 1 }, as: :json
    assert_response :bad_request
    assert_equal 2, chat.agents.reload.count
  end

  test "update treats a seat removed mid-batch as already done and finishes the rest" do
    first = agents(:research_assistant)
    second = agents(:code_reviewer)
    chat = create_group_chat(@account, agent_ids: [ first.id, second.id ])
    # A concurrent removal of `second` lands after this request read the seats.
    race = ->(seat) { ChatAgent.where(chat_id: seat.chat_id, agent_id: second.id).delete_all if seat.agent_id == first.id }
    ChatAgent.before_destroy(race)
    begin
      patch account_chat_participant_path(@account, chat), params: { agent_ids: [] }, as: :json
    ensure
      ChatAgent.skip_callback(:destroy, :before, race)
    end

    assert_redirected_to account_chat_path(@account, chat)
    assert_nil flash[:alert]
    assert_empty chat.agents.reload
    left = chat.messages.where("content LIKE ?", "%has left the conversation.").pluck(:content)
    assert_equal [ "[System Notice] #{first.name} has left the conversation." ], left
  end

  test "remove_participant! is a no-op for a seat that is already gone" do
    agent = agents(:research_assistant)
    chat = create_group_chat(@account, agent_ids: [ agent.id ])
    chat.chat_agents.delete_all

    assert_no_difference -> { chat.messages.count } do
      assert_equal false, chat.remove_participant!(agent, by: @user)
    end
  end

  test "chat agents include current human removal capability" do
    chat = create_group_chat(@account, agent_ids: [ agents(:research_assistant).id ])
    get account_chat_path(@account, chat)
    assert_response :success
    assert_equal true, inertia_shared_props.dig("agents", 0, "can_remove_from_chat")
  end

  private

  def create_group_chat(account, agent_ids:)
    chat = account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    chat.agent_ids = agent_ids
    chat.save!
    chat
  end

end
