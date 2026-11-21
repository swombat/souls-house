require "test_helper"

# What follows a private conversation out of it (eKmnrJ, Mira #1089): its
# commitments, its stone's late deliveries, and its runs on account pages.
class PrivateFollowThroughTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:team_account)
    @creator = @account.memberships.find_by!(role: "member").user
    @admin = @account.memberships.find_by!(role: "owner").user
    @agent = @account.agents.create!(name: "Inside", runtime: "external", model_id: "openrouter/auto", system_prompt: "x")
    @chat = @account.chats.create_with_message!({ title: "Secret", private: true, manual_responses: true },
      user: @creator, agent_ids: [ @agent.id ], automatic_response: false)
  end

  test "a commitment from a private conversation wakes only there and is hidden from outsiders" do
    away = Commitment.new(agent: @agent, source_chat: @chat, text: "Ask about the quinces", due_at: 1.hour.from_now,
      destination: "new_conversation")
    refute away.valid?
    assert away.errors[:destination].any?

    home = Commitment.create!(agent: @agent, source_chat: @chat, text: "Ask about the quinces", due_at: 1.hour.from_now)
    assert_includes CommitmentPresentation.visible_scope(agent: @agent, account: @account, viewer: @creator), home
    refute_includes CommitmentPresentation.visible_scope(agent: @agent, account: @account, viewer: @admin), home
  end

  test "a run in a private conversation says nothing more on account-wide pages" do
    run = AgentRuntimeInteraction.create!(agent: @agent, chat: @chat, trigger_kind: "wake", started_at: Time.current,
      stdout: "the quince jelly")
    json = run.as_session_json
    assert_equal "A private conversation", json[:chat_title]
    assert_nil json[:chat_id]
    assert_nil json[:stdout]
    assert_nil json[:conversation_id]
  end

end
