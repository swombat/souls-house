require "test_helper"

class ApiKeysControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:team_account)
    Setting.instance.update!(allow_agents: true)
    sign_in(@user)
  end

  test "legacy API keys URL redirects to account-scoped external access" do
    get api_keys_path

    assert_redirected_to account_api_keys_path(@user.default_account)
  end

  test "index lists only the current user's keys for the selected account" do
    included = ApiKey.generate_for(@user, account: @account, name: "Included")
    ApiKey.generate_for(@user, account: accounts(:personal_account), name: "Other Account")

    get account_api_keys_path(@account)

    assert_response :success
    assert_equal "api_keys/index", inertia_component
    assert_equal [ included.id ], inertia_shared_props.fetch("external_access_keys").map { |key| key.fetch("id") }
  end

  test "index inventories both kinds of resident keys without management controls" do
    agent = agents(:other_account_agent)
    key = ApiKey.generate_for(@user, agent: agent, name: "Chaos Agent")
    agent.update!(outbound_api_key: key)
    desktop = ApiKey.generate_for(@user, agent: agent, name: "Desktop")

    get account_api_keys_path(@account)

    agent_keys = inertia_shared_props.fetch("resident_keys")
    assert_equal({ desktop.id => "other_body", key.id => "house" }, agent_keys.to_h { |item| item.values_at("id", "kind") })
    assert_equal(
      { "type" => "agent", "id" => agent.to_param, "name" => agent.name },
      agent_keys.first.fetch("actor")
    )
    assert agent_keys.none? { |item| item.key?("revoke_url") }
    assert_not_includes response.body, desktop.raw_token
    assert_empty inertia_shared_props.fetch("external_access_keys")
    assert_includes inertia_shared_props.fetch("key_residents"), {
      "id" => agent.to_param,
      "name" => agent.name,
      "resident_active" => true,
      "settings_url" => edit_account_agent_path(@account, agent, tab: "settings", anchor: "connect-another-body")
    }
  end

  test "index marks disabled residents and their keys for the disclosure" do
    agent = agents(:other_account_agent)
    agent.update_columns(active: false)
    key = ApiKey.generate_for(@user, agent: agent, name: "Desktop")

    get account_api_keys_path(@account)

    assert_equal false, inertia_shared_props.fetch("resident_keys").find { |item| item["id"] == key.id }.fetch("resident_active")
    assert_equal false, inertia_shared_props.fetch("key_residents").find { |item| item["id"] == agent.to_param }.fetch("resident_active")
  end

  test "index omits resident settings links for non-owners" do
    sign_in(users(:existing_user))

    get account_api_keys_path(@account)

    assert_response :success
    assert_empty inertia_shared_props.fetch("key_residents")
  end

  test "create scopes the external access key to the selected account" do
    assert_difference "ApiKey.count", 1 do
      post account_api_keys_path(@account), params: { name: "Claude Code" }
    end

    assert_response :success
    key = ApiKey.order(:created_at).last
    assert_equal @account, key.account
    assert_equal @user, key.user
  end

  test "destroy revokes an approved key while preserving its request history" do
    request = ApiKeyRequest.create_request(client_name: "Lume")
    key = request.approve!(user: @user, account: @account, key_name: "Lume")

    assert_difference "ApiKey.count", -1 do
      delete account_api_key_path(@account, key)
    end

    assert_redirected_to account_api_keys_path(@account)
    assert_nil request.reload.api_key
    assert_equal "approved", request.status
  end

  test "destroy cannot revoke a key from another account" do
    key = ApiKey.generate_for(@user, account: accounts(:personal_account), name: "Other Account")

    delete account_api_key_path(@account, key)

    assert_response :not_found
    assert key.reload.persisted?
  end

  test "destroy cannot revoke a system-managed Chaos agent key" do
    agent = agents(:other_account_agent)
    key = ApiKey.generate_for(@user, agent: agent, name: "Chaos Agent")

    delete account_api_key_path(@account, key)

    assert_response :not_found
    assert key.reload.persisted?
  end

end
