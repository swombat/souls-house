require "test_helper"
require "action_cable/test_helper"

class ChatSidebarActivityTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  setup do
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(title: "Working here", manual_responses: true, agents: [ @agent ])
    @other = @agent.account.chats.create!(title: "Not here", manual_responses: true, agents: [ @agent ])
  end

  test "sidebar overlays fresh room-specific run state on cached content without reordering chats" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    timestamp = @chat.updated_at
    assert_empty sidebar(@chat)["working_agent_ids"]
    interaction = create_run

    assert_equal [ @agent.to_param ], sidebar(@chat)["working_agent_ids"]
    assert_empty sidebar(@other)["working_agent_ids"]
    assert_equal @agent.to_param, sidebar(@chat)["participants_json"].first[:id]
    assert_equal timestamp, @chat.reload.updated_at

    interaction.update!(execution_state: "completed", finished_at: Time.current)
    assert_empty sidebar(@chat)["working_agent_ids"]
    assert_equal timestamp, @chat.reload.updated_at
  ensure
    Rails.cache = original_cache
  end

  test "queued and running interactions remain visible but every terminal state stops the ring" do
    interaction = create_run
    %w[queued preparing running].each do |state|
      interaction.update!(execution_state: state)
      assert_equal [ @agent.to_param ], sidebar(@chat)["working_agent_ids"]
    end
    AgentRuntimeInteraction::TERMINAL_STATES.each do |state|
      interaction.update!(execution_state: state)
      assert_empty sidebar(@chat)["working_agent_ids"], state
    end
  end

  test "legacy runs expire and multiple runs for the same resident yield only one id" do
    first = create_run(run_id: nil, execution_state: nil)
    second = create_run(run_id: nil, execution_state: nil)
    assert_equal [ @agent.to_param ], sidebar(@chat)["working_agent_ids"]
    first.update!(finished_at: Time.current)
    assert_equal [ @agent.to_param ], sidebar(@chat)["working_agent_ids"]
    second.update!(started_at: 13.minutes.ago)
    assert_empty sidebar(@chat)["working_agent_ids"]
  end

  test "lifecycle transitions refresh the account sidebar but telemetry updates do not" do
    channel = "Account:#{@agent.account.to_param}"
    interaction = nil
    assert_broadcast_on(channel, action: "refresh", prop: "chats") { interaction = create_run }
    assert_no_broadcasts(channel) { interaction.update!(stdout: "diagnostic") }
    assert_broadcast_on(channel, action: "refresh", prop: "chats") do
      interaction.update!(execution_state: "completed", finished_at: Time.current)
    end
    assert_broadcast_on(channel, action: "refresh", prop: "chats") { interaction.destroy! }
  end

  private

  def sidebar(chat)
    Chat.sidebar_json_for([ chat ]).first
  end

  def create_run(**attributes)
    AgentRuntimeInteraction.create!({
      agent: @agent, chat: @chat, trigger_kind: "conversation",
      started_at: Time.current, run_id: SecureRandom.uuid, execution_state: "running"
    }.merge(attributes))
  end

end
