require "test_helper"

# A resident whose last run in a conversation ended in an error shows a red
# circled exclamation mark in the sidebar, over the hand and the clock
# (Daniel, 13 Nov, jgDWoJ).
class ChatSidebarRunErrorTest < ActiveSupport::TestCase

  setup do
    @lume = agents(:research_assistant)
    @mira = agents(:code_reviewer)
    @account = @lume.account
    @chat = @account.chats.create!(manual_responses: true, agents: [ @lume, @mira ])
    @other = @account.chats.create!(manual_responses: true, agents: [ @lume, @mira ])
  end

  test "a live run that failed marks the conversation with the resident's name" do
    record_run(@lume, @chat, execution_state: "failed")

    assert_equal [ @lume.name ], sidebar(@chat)["run_error_residents"]
    assert_equal [], sidebar(@other)["run_error_residents"]
  end

  test "a timeout counts; a cancellation or a busy refusal does not" do
    record_run(@lume, @chat, execution_state: "timed_out")
    record_run(@mira, @chat, execution_state: "cancelled")
    assert_equal [ @lume.name ], sidebar(@chat)["run_error_residents"]

    record_run(@lume, @other, execution_state: "busy")
    assert_equal [], sidebar(@other)["run_error_residents"]
  end

  test "only the newest run counts: a clean run after the error clears it, and so does a new run starting" do
    record_run(@lume, @chat, execution_state: "failed")
    record_run(@lume, @chat, execution_state: "completed")
    assert_equal [], sidebar(@chat)["run_error_residents"]

    record_run(@lume, @chat, execution_state: "failed")
    record_run(@lume, @chat, execution_state: "running", finished: false)
    assert_equal [], sidebar(@chat)["run_error_residents"]
  end

  test "an older run without live activity counts when it finished with an error" do
    record_run(@mira, @chat, execution_state: nil, error_message: "runtime exited 1", runtime_returncode: 1)
    record_run(@lume, @chat, execution_state: nil)

    assert_equal [ @mira.name ], sidebar(@chat)["run_error_residents"]
  end

  test "both residents are named when both last runs failed" do
    record_run(@lume, @chat, execution_state: "failed")
    record_run(@mira, @chat, execution_state: "failed")

    assert_equal [ @lume.name, @mira.name ].sort, sidebar(@chat)["run_error_residents"]
  end

  test "a resident who has left the room no longer marks it" do
    record_run(@mira, @chat, execution_state: "failed")
    @chat.chat_agents.where(agent: @mira).destroy_all

    assert_equal [], sidebar(@chat)["run_error_residents"]
  end

  private

  def record_run(agent, chat, execution_state:, finished: true, **attrs)
    AgentRuntimeInteraction.create!(agent: agent, chat: chat, trigger_kind: "manual", session_id: "s-#{SecureRandom.hex(4)}",
      endpoint_url: "https://runtime.example.test", started_at: Time.current,
      finished_at: (Time.current if finished), execution_state: execution_state, **attrs)
  end

  def sidebar(chat)
    Chat.sidebar_json_for([ chat ]).first
  end

end
