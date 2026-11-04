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

  test "a cloud resident's card carries its VM type, size and monthly list price" do
    agent = agents(:research_assistant)
    AgentPlacement.where(agent: agent).delete_all
    placement = AgentPlacement.create!(agent: agent, backend: "hetzner_cloud", state: "ready", location: "nbg1",
      provider_server_id: 4242)
    CloudProcurementOperation.create!(agent_placement: placement, requested_by: users(:site_admin_user),
      public_id: SecureRandom.hex(4), approval_reference: "test", location: "nbg1", server_type: "cx33",
      image_id: 1, ssh_key_ids: [ 1 ], provider_name: "resident-#{SecureRandom.hex(3)}", state: "provisioned",
      provider_server_id: 4242)
    HouseSample.create!(kind: "pricing", sampled_at: 1.hour.ago,
      metrics: { "hetzner_eur_per_month" => { "cx33" => { "nbg1" => 6.49, "fsn1" => 6.2 } } })

    sign_in users(:site_admin_user)
    get admin_residents_path
    card = inertia_props["props"]["residents"].find { |resident| resident["name"] == agent.name && resident["account_name"] == agent.account.name }
    assert_equal({ "kind" => "cloud", "state" => "ready", "location" => "nbg1", "server_type" => "cx33",
                   "vcpus" => 4, "ram_gb" => 8, "disk_gb" => 80, "eur_per_month" => 6.49 }, card["hosting"])
  end

  test "a cloud resident with no pricing sample shows its type without a price" do
    agent = agents(:research_assistant)
    AgentPlacement.where(agent: agent).delete_all
    placement = AgentPlacement.create!(agent: agent, backend: "hetzner_cloud", state: "pending", location: "fsn1")
    CloudProcurementOperation.create!(agent_placement: placement, requested_by: users(:site_admin_user),
      public_id: SecureRandom.hex(4), approval_reference: "test", location: "fsn1", server_type: "cx23",
      image_id: 1, ssh_key_ids: [ 1 ], provider_name: "resident-#{SecureRandom.hex(3)}", state: "create_in_flight")
    HouseSample.of_kind("pricing").delete_all

    sign_in users(:site_admin_user)
    get admin_residents_path
    card = inertia_props["props"]["residents"].find { |resident| resident["name"] == agent.name && resident["account_name"] == agent.account.name }
    assert_equal "cx23", card["hosting"]["server_type"]
    assert_nil card["hosting"]["eur_per_month"]
  end

end
