require "test_helper"

class Api::V1::AgentAppearancesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(colour: "violet", icon: "Eye")
    @resident_key = ApiKey.generate_for(@agent.account.owner, name: "resident", agent: @agent)
    @owner_key = ApiKey.generate_for(@agent.account.owner, name: "owner")
  end

  test "a resident reads its current appearance alongside the allowed colours and icons" do
    @agent.avatar.attach(io: file_fixture("test_avatar.png").open, filename: "a.png", content_type: "image/png")

    get "/api/v1/agent/appearance", headers: auth(@resident_key)

    assert_response :success
    body = response.parsed_body
    assert_equal "violet", body["colour"]
    assert_equal "Eye", body["icon"]
    assert_equal @agent.reload.avatar_url, body["avatar_url"]
    assert_equal Agent::VALID_COLOURS, body["colours"]
    assert_equal Agent::VALID_ICONS, body["icons"]
  end

  test "a resident sets colour and icon together, audited as the resident" do
    patch "/api/v1/agent/appearance", params: { colour: "teal", icon: "Leaf" }, as: :json, headers: auth(@resident_key)

    assert_response :success
    @agent.reload
    assert_equal "teal", @agent.colour
    assert_equal "Leaf", @agent.icon
    assert_equal({ "colour" => "teal", "icon" => "Leaf", "avatar_url" => nil }, response.parsed_body)

    log = AuditLog.find_by!(action: "set_agent_appearance", auditable: @agent)
    assert_nil log.user
    assert_equal @agent.account, log.account
    assert_equal @agent.id, log.data["agent_id"]
    assert_equal @resident_key.id, log.data["api_key_id"]
    assert_equal "resident", log.data["by"]
    assert_equal "teal", log.data["colour"]
    assert_equal "Leaf", log.data["icon"]
  end

  test "omitted fields stay as they are; null or blank clears only the named field" do
    patch "/api/v1/agent/appearance", params: { colour: "  teal  " }, as: :json, headers: auth(@resident_key)
    assert_response :success
    assert_equal [ "teal", "Eye" ], [ @agent.reload.colour, @agent.icon ]

    patch "/api/v1/agent/appearance", params: { icon: "Leaf" }, as: :json, headers: auth(@resident_key)
    assert_response :success
    assert_equal [ "teal", "Leaf" ], [ @agent.reload.colour, @agent.icon ]

    patch "/api/v1/agent/appearance", params: { colour: nil }, as: :json, headers: auth(@resident_key)
    assert_response :success
    assert_nil @agent.reload.colour
    assert_equal "Leaf", @agent.icon

    patch "/api/v1/agent/appearance", params: { icon: "   " }, as: :json, headers: auth(@resident_key)
    assert_response :success
    assert_nil @agent.reload.colour
    assert_nil @agent.icon
  end

  test "choices outside the allowlists, non-scalar values, and an empty body are refused without changing anything" do
    patch "/api/v1/agent/appearance", params: { colour: "chartreuse", icon: "Waveform" }, as: :json, headers: auth(@resident_key)
    assert_response :unprocessable_entity
    assert_equal 2, response.parsed_body["errors"].size

    patch "/api/v1/agent/appearance", params: { colour: [ "teal" ] }, as: :json, headers: auth(@resident_key)
    assert_response :unprocessable_entity
    assert_includes response.parsed_body["errors"], "Colour must be a colour name or null"

    patch "/api/v1/agent/appearance", params: { icon: { name: "Leaf" } }, as: :json, headers: auth(@resident_key)
    assert_response :unprocessable_entity
    assert_includes response.parsed_body["errors"], "Icon must be an icon name or null"

    patch "/api/v1/agent/appearance", params: {}, as: :json, headers: auth(@resident_key)
    assert_response :unprocessable_entity
    assert_equal [ "send colour and/or icon (use null to clear)" ], response.parsed_body["errors"]

    @agent.reload
    assert_equal "violet", @agent.colour
    assert_equal "Eye", @agent.icon
    assert_not AuditLog.exists?(action: "set_agent_appearance", auditable: @agent)
  end

  test "changing appearance refreshes guest directory and discovery presentation" do
    guest_refreshes = []
    discovery_refreshes = []
    original_guest = GuestDirectory.method(:refresh!)
    original_discovery = GuestDiscovery.method(:refresh_accounts!)

    GuestDirectory.stub(:refresh!, ->(ids) { guest_refreshes.concat(Array(ids)); original_guest.call(ids) }) do
      GuestDiscovery.stub(:refresh_accounts!, ->(ids) { discovery_refreshes.concat(Array(ids)); original_discovery.call(ids) }) do
        patch "/api/v1/agent/appearance", params: { colour: "teal" }, as: :json, headers: auth(@resident_key)
      end
    end

    assert_response :success
    assert_includes guest_refreshes, @agent.account_id
    assert_includes discovery_refreshes, @agent.account_id
  end

  test "a human key and unauthenticated requests are refused" do
    get "/api/v1/agent/appearance", headers: auth(@owner_key)
    assert_response :forbidden

    patch "/api/v1/agent/appearance", params: { colour: "teal" }, as: :json, headers: auth(@owner_key)
    assert_response :forbidden

    get "/api/v1/agent/appearance"
    assert_response :unauthorized

    assert_equal "violet", @agent.reload.colour
  end

  private

  def auth(key)
    { Authorization: "Bearer #{key.raw_token}" }
  end

end
