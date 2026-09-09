require "test_helper"
require Rails.root.join("db/migrate/20260909170000_enable_working_narration_by_default")

class WorkingNarrationDefaultTest < ActiveSupport::TestCase

  test "new residents share working narration by default" do
    assert Agent.new.share_working_narration?
    agent = agents(:research_assistant).account.agents.create!(name: "Narration default")
    assert agent.reload.share_working_narration?
  end

  test "rollout enables existing residents without changing historical run consent" do
    agent = agents(:research_assistant)
    agent.update!(share_working_narration: false)
    chat = agent.account.chats.create!(title: "Narration rollout", manual_responses: true, agents: [ agent ])
    old_run = AgentRuntimeInteraction.reserve!(agent: agent, chat: chat)
    assert_not old_run.narration_shared?

    EnableWorkingNarrationByDefault.new.migrate(:up)
    assert agent.reload.share_working_narration?
    assert_not old_run.reload.narration_shared?
    old_run.update!(finished_at: Time.current, execution_state: "completed")
    next_run = AgentRuntimeInteraction.reserve!(agent: agent, chat: chat)
    next_run.claim_dispatch!
    assert next_run.activity_configuration![:share_narration]
    agent.update!(share_working_narration: false)
    assert_not next_run.activity_configuration![:share_narration]
  end

end
