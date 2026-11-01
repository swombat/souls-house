require "test_helper"

class Admin::ResidentsControllerTest < ActionDispatch::IntegrationTest

  test "site admins see every account's residents with hosting and owner; others are sent away" do
    agent = agents(:research_assistant)
    AgentPlacement.where(agent: agent).delete_all
    AgentPlacement.create!(agent: agent, backend: "hetzner_cloud", state: "pending", kind: "birth")

    sign_in users(:site_admin_user)
    get admin_residents_path
    assert_response :success
    assert_equal "admin/residents", inertia_component
    residents = inertia_props["props"]["residents"]
    assert_equal Agent.count, residents.size

    card = residents.find { |resident| resident["name"] == agent.name && resident["account_name"] == agent.account.name }
    assert_equal({ "kind" => "cloud", "state" => "pending", "location" => nil }, card["hosting"])
    assert_equal agent.account.owner&.email_address, card["owner_email"]
    assert card.key?("activity")

    local = residents.find { |resident| resident["hosting"]["kind"] == "local" }
    assert local, "a resident without a placement runs on the house server"
  end

  test "the site admin sees each resident's running sessions and the site's totals" do
    agent = agents(:research_assistant)
    AgentPlacement.where(agent: agent).delete_all
    AgentRuntimeInteraction.create!(agent: agent, trigger_kind: "telegram", started_at: Time.current,
      run_id: SecureRandom.uuid, execution_state: "running")

    sign_in users(:site_admin_user)
    get admin_residents_path
    props = inertia_props["props"]
    assert_equal({ "chat" => 0, "telegram" => 1, "other" => 0 }, props["active_sessions"].fetch(agent.to_param))
    assert_equal 1, props["active_session_totals"]["all"]["telegram"]
    assert_equal 1, props["active_session_totals"]["house"]["telegram"]
    assert_equal 0, props["active_session_totals"]["vm"]["telegram"]
  end

  test "people who are not site admins are redirected" do
    sign_in users(:user_1)
    get admin_residents_path
    assert_redirected_to root_path
  end

end
