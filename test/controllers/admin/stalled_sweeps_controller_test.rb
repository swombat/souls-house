require "test_helper"

class Admin::StalledSweepsControllerTest < ActionDispatch::IntegrationTest

  test "site admins see the verdict log; others are sent away" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(title: "Quiet room", manual_responses: true, agents: [ agent ])
    message = chat.messages.create!(role: "assistant", agent: agent, content: "Merging once green.")
    StalledThreadSweep.create!(account: chat.account, chat: chat, message: message, outcome: "would_wake",
      scores: [ { agent_id: agent.to_param, name: agent.name, score: 0.91 } ], person_holds: 0.1,
      would_wake: [ agent.name ], quiet_minutes: 45, prompt_version: "v3")

    sign_in users(:site_admin_user)
    get admin_stalled_sweeps_path
    assert_response :success
    assert_equal "admin/stalled-sweeps", inertia_component
    sweep = inertia_props["props"]["sweeps"].sole
    assert_equal [ "would_wake", [ agent.name ], false ], sweep.values_at("outcome", "would_wake", "moved_on")
  end

end
