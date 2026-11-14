require "test_helper"

# A resident whose last run here missed an expected Chaos hook shows a yellow
# mark in the sidebar slot, below the red error mark (jaMBVj).
class ChatSidebarHookWarningTest < ActiveSupport::TestCase

  setup do
    @lume = agents(:research_assistant)
    @mira = agents(:code_reviewer)
    @chat = @lume.account.chats.create!(manual_responses: true, agents: [ @lume, @mira ])
  end

  test "the newest run's warning marks the conversation, and a clean run clears it" do
    record_run(@lume, hook_warning: "Chaos hooks: no wake (session_start) hook is configured.")
    record_run(@mira)
    assert_equal [ @lume.name ], sidebar["hook_warning_residents"]

    record_run(@lume)
    assert_equal [], sidebar["hook_warning_residents"]
  end

  test "a resident who left the room no longer marks it" do
    record_run(@mira, hook_warning: "Chaos hooks: no stop hook is configured.")
    @chat.chat_agents.where(agent: @mira).destroy_all

    assert_equal [], sidebar["hook_warning_residents"]
  end

  private

  def record_run(agent, **attrs)
    AgentRuntimeInteraction.create!(agent: agent, chat: @chat, trigger_kind: "manual", session_id: "s-#{SecureRandom.hex(4)}",
      endpoint_url: "https://runtime.example.test", started_at: Time.current, finished_at: Time.current, **attrs)
  end

  def sidebar
    Chat.sidebar_json_for([ @chat ]).first
  end

end
