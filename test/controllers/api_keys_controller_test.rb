require "test_helper"

class ApiKeysControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:team_account)
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

  test "index separates Chaos agent keys and identifies the bound agent" do
    agent = agents(:other_account_agent)
    key = ApiKey.generate_for(@user, agent: agent, name: "Chaos Agent")
    agent.update!(outbound_api_key: key) # the container key; named keys are listed apart

    get account_api_keys_path(@account)

    agent_keys = inertia_shared_props.fetch("chaos_agent_access_keys")
    assert_equal [ key.id ], agent_keys.map { |item| item.fetch("id") }
    assert_equal(
      { "type" => "agent", "id" => agent.to_param, "name" => agent.name },
      agent_keys.first.fetch("actor")
    )
    assert_empty inertia_shared_props.fetch("external_access_keys")
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
