require "test_helper"

class AgentInitiationTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @account = @agent.account
    @user = users(:user_1)
  end

  # Helper to create a pending initiation
  def create_pending_initiation(agent)
    Chat.initiate_by_agent!(
      agent,
      topic: "Test Topic #{SecureRandom.hex(4)}",
      message: "Test message"
    )
  end

  # Helper to create a manual chat with agent
  def create_manual_chat_with_agent(agent, title: "Test Chat")
    chat = @account.chats.new(
      title: title,
      manual_responses: true,
      model_id: agent.model_id
    )
    chat.agent_ids = [ agent.id ]
    chat.save!
    chat
  end

  test "at_initiation_cap? returns false when no pending initiations" do
    refute @agent.at_initiation_cap?
  end

  test "at_initiation_cap? returns false when under limit" do
    create_pending_initiation(@agent)

    refute @agent.at_initiation_cap?
  end

  test "at_initiation_cap? returns true when at limit" do
    Agent::INITIATION_CAP.times { create_pending_initiation(@agent) }

    assert @agent.at_initiation_cap?
  end

  test "at_initiation_cap? returns false after human response" do
    chat = create_pending_initiation(@agent)
    create_pending_initiation(@agent)
    chat.messages.create!(role: "user", user: @user, content: "Thanks!")

    refute @agent.at_initiation_cap?
  end

  test "discarded chats do not count against initiation cap" do
    chat = create_pending_initiation(@agent)
    create_pending_initiation(@agent)
    chat.discard!

    refute @agent.at_initiation_cap?
  end

  test "archived chats still count against initiation cap" do
    chat1 = create_pending_initiation(@agent)
    chat2 = create_pending_initiation(@agent)
    chat1.archive!

    # Archived chats are still "kept" (not discarded), so they count
    assert @agent.at_initiation_cap?
  end

  test "pending_initiated_conversations returns only pending agent-initiated chats" do
    pending_chat = create_pending_initiation(@agent)
    responded_chat = create_pending_initiation(@agent)
    responded_chat.messages.create!(role: "user", user: @user, content: "Thanks!")

    pending = @agent.pending_initiated_conversations

    assert_includes pending, pending_chat
    assert_not_includes pending, responded_chat
  end

  test "last_initiation_at returns timestamp of most recent initiation" do
    travel_to 2.days.ago do
      create_pending_initiation(@agent)
    end

    recent_chat = travel_to 1.hour.ago do
      create_pending_initiation(@agent)
    end

    assert_in_delta recent_chat.created_at.to_i, @agent.last_initiation_at.to_i, 1
  end

  test "last_initiation_at returns nil when no initiations" do
    assert_nil @agent.last_initiation_at
  end

  test "continuable_conversations returns manual response chats" do
    chat = create_manual_chat_with_agent(@agent, title: "Group Chat")
    chat.messages.create!(role: "user", user: @user, content: "Hello!")

    conversations = @agent.continuable_conversations

    assert_includes conversations, chat
  end

  test "continuable_conversations excludes non-manual chats" do
    chat = @account.chats.create!(
      title: "Auto Chat",
      manual_responses: false
    )
    chat.chat_agents.create!(agent: @agent)

    conversations = @agent.continuable_conversations

    assert_not_includes conversations, chat
  end

  test "continuable_conversations excludes archived chats" do
    chat = create_manual_chat_with_agent(@agent, title: "Archived Chat")
    chat.messages.create!(role: "user", user: @user, content: "Hello!")
    chat.archive!

    conversations = @agent.continuable_conversations

    assert_not_includes conversations, chat
  end

  test "continuable_conversations excludes discarded chats" do
    chat = create_manual_chat_with_agent(@agent, title: "Discarded Chat")
    chat.messages.create!(role: "user", user: @user, content: "Hello!")
    chat.discard!

    conversations = @agent.continuable_conversations

    assert_not_includes conversations, chat
  end

  test "continuable_conversations excludes chats where agent spoke last" do
    chat = create_manual_chat_with_agent(@agent, title: "Agent Last Chat")
    chat.messages.create!(role: "user", user: @user, content: "Hello!")
    chat.messages.create!(role: "assistant", agent: @agent, content: "Hi there!")

    conversations = @agent.continuable_conversations

    assert_not_includes conversations, chat
  end

  test "does not build inline decision prompts" do
    assert_not @agent.respond_to?(:build_initiation_prompt)
  end

  test "INITIATION_CAP constant is defined" do
    assert_equal 2, Agent::INITIATION_CAP
  end

  test "AGENT_ONLY_INITIATION_CAP constant is defined" do
    assert_equal 2, Agent::AGENT_ONLY_INITIATION_CAP
  end

  test "RECENTLY_INITIATED_WINDOW constant is defined" do
    assert_equal 48.hours, Agent::RECENTLY_INITIATED_WINDOW
  end

  # Agent-only cap tests

  test "at_agent_only_initiation_cap? returns false when no agent-only initiations" do
    refute @agent.at_agent_only_initiation_cap?
  end

  test "at_agent_only_initiation_cap? returns true when at limit" do
    Agent::AGENT_ONLY_INITIATION_CAP.times do |i|
      Chat.initiate_by_agent!(
        @agent,
        topic: "#{Chat::AGENT_ONLY_PREFIX} Topic #{i}",
        message: "Test message"
      )
    end

    assert @agent.at_agent_only_initiation_cap?
  end

  test "at_agent_only_initiation_cap? ignores initiations older than 48 hours" do
    travel_to 49.hours.ago do
      Agent::AGENT_ONLY_INITIATION_CAP.times do |i|
        Chat.initiate_by_agent!(
          @agent,
          topic: "#{Chat::AGENT_ONLY_PREFIX} Old Topic #{i}",
          message: "Test message"
        )
      end
    end

    refute @agent.at_agent_only_initiation_cap?
  end

  test "agent-only chats do not count against human initiation cap" do
    Agent::AGENT_ONLY_INITIATION_CAP.times do |i|
      Chat.initiate_by_agent!(
        @agent,
        topic: "#{Chat::AGENT_ONLY_PREFIX} Topic #{i}",
        message: "Test message"
      )
    end

    refute @agent.at_initiation_cap?
  end

  test "human chats do not count against agent-only initiation cap" do
    Agent::INITIATION_CAP.times { create_pending_initiation(@agent) }

    refute @agent.at_agent_only_initiation_cap?
  end

  # Closed-for-initiation tests

  test "continuable_conversations excludes chats closed for initiation" do
    chat = create_manual_chat_with_agent(@agent, title: "Closed Chat")
    chat.messages.create!(role: "user", user: @user, content: "Hello!")

    chat.chat_agents.find_by(agent: @agent).close_for_initiation!

    conversations = @agent.continuable_conversations

    assert_not_includes conversations, chat
  end

  test "continuable_conversations includes chats reopened after closing" do
    chat = create_manual_chat_with_agent(@agent, title: "Reopened Chat")
    chat.messages.create!(role: "user", user: @user, content: "Hello!")

    chat_agent = chat.chat_agents.find_by(agent: @agent)
    chat_agent.close_for_initiation!
    chat_agent.reopen_for_initiation!

    conversations = @agent.continuable_conversations

    assert_includes conversations, chat
  end

  test "closing for one agent does not affect another agent" do
    other_agent = agents(:code_reviewer)
    chat = create_manual_chat_with_agent(@agent, title: "Multi-Agent Chat")
    chat.chat_agents.create!(agent: other_agent)
    chat.messages.create!(role: "user", user: @user, content: "Hello!")

    # Close for @agent only
    chat.chat_agents.find_by(agent: @agent).close_for_initiation!

    # Other agent should still see the chat
    assert_includes other_agent.continuable_conversations, chat
    assert_not_includes @agent.continuable_conversations, chat
  end

end
