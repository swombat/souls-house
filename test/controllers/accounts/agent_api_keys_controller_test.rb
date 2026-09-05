require "test_helper"

class Accounts::AgentApiKeysControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:team_account)
    sign_in(@user)
  end

  test "show reports configured keys without exposing them" do
    @account.update!(openrouter_api_key: "secret-account-key")

    get account_agent_api_keys_path(@account)

    assert_response :success
    assert_equal "accounts/agent_api_keys", inertia_component
    assert_equal true, inertia_shared_props.dig("ai_api_keys_configured", "openrouter")
    assert_not_includes response.body, "secret-account-key"
  end

  test "show includes subscription setup for eligible hosted agents" do
    agent = agents(:other_account_agent)
    agent.update!(
      model_id: "openai/gpt-5",
      runtime: "external",
      health_state: "healthy",
      provider_auth_modes: { "openai" => "oauth_account" },
      provider_connections: {
        "openai" => {
          "status" => "connected",
          "email" => "subscriber@example.com",
          "connected_at" => Time.current.iso8601
        }
      }
    )

    get account_agent_api_keys_path(@account)

    subscription_agent = inertia_shared_props.fetch("subscription_agents").find { |item| item.fetch("id") == agent.to_param }
    assert_equal "openai", subscription_agent.fetch("provider")
    assert_equal "oauth_account", subscription_agent.fetch("auth_mode")
    assert_equal "subscriber@example.com", subscription_agent.dig("connection", "email")
  end

  test "show includes Claude clamping setup for hosted Anthropic agents" do
    agent = agents(:other_account_agent)
    agent.update!(
      model_id: "anthropic/claude-opus-4.7",
      runtime: "external",
      health_state: "healthy"
    )

    get account_agent_api_keys_path(@account)

    subscription_agent = inertia_shared_props.fetch("subscription_agents").find { |item| item.fetch("id") == agent.to_param }
    assert_equal "anthropic", subscription_agent.fetch("provider")
    assert_equal "Claude", subscription_agent.fetch("provider_name")
    assert_equal "api_key", subscription_agent.fetch("auth_mode")
    assert_equal true, subscription_agent.fetch("available")
  end

  test "show includes Antigravity clamping setup for hosted Gemini agents" do
    agent = agents(:other_account_agent)
    agent.update!(
      model_id: "google/gemini-3.7-flash",
      runtime: "external",
      health_state: "healthy"
    )

    get account_agent_api_keys_path(@account)

    subscription_agent = inertia_shared_props.fetch("subscription_agents").find { |item| item.fetch("id") == agent.to_param }
    assert_equal "gemini", subscription_agent.fetch("provider")
    assert_equal "Google AI", subscription_agent.fetch("provider_name")
    assert_equal "api_key", subscription_agent.fetch("auth_mode")
    assert_equal true, subscription_agent.fetch("available")
  end

  test "show excludes inline agents from subscription setup" do
    agent = agents(:other_account_agent)
    agent.update!(model_id: "openai/gpt-5", runtime: "deprecated")

    get account_agent_api_keys_path(@account)

    subscription_agent_ids = inertia_shared_props.fetch("subscription_agents").pluck("id")
    assert_not_includes subscription_agent_ids, agent.to_param
  end

  test "updates per-account agent API keys" do
    @account.update!(use_system_ai_credentials: true)

    assert_enqueued_with(job: AccountAgentCredentialsRefreshJob, args: [ @account.id ]) do
      patch account_agent_api_keys_path(@account), params: {
        account: {
          openrouter_api_key: "account-openrouter-key",
          moonshot_api_key: "account-moonshot-key",
          zai_api_key: "account-zai-key",
          minimax_api_key: "account-minimax-key",
          use_system_ai_credentials: false
        }
      }
    end

    assert_redirected_to account_agent_api_keys_path(@account)
    @account.reload
    assert_equal "account-openrouter-key", @account.openrouter_api_key
    assert_equal "account-moonshot-key", @account.moonshot_api_key
    assert_equal "account-zai-key", @account.zai_api_key
    assert_equal "account-minimax-key", @account.minimax_api_key
    assert @account.use_system_ai_credentials?
  end

  test "key changes are filtered from audit logs" do
    patch account_agent_api_keys_path(@account), params: {
      account: { anthropic_api_key: "sk-ant-secret-value" }
    }

    audit = AuditLog.order(:created_at).last
    assert_equal "update_agent_api_keys", audit.action
    assert_equal "[FILTERED]", audit.data.fetch("anthropic_api_key")
    assert_not_includes audit.data.to_json, "sk-ant-secret-value"
  end

  test "blank fields preserve configured keys" do
    @account.update!(openai_api_key: "existing-key")

    patch account_agent_api_keys_path(@account), params: {
      account: { openai_api_key: "" }
    }

    assert_equal "existing-key", @account.reload.openai_api_key
  end

  test "configured keys can be removed" do
    @account.update!(xai_api_key: "existing-key")

    patch account_agent_api_keys_path(@account), params: {
      account: { clear_ai_api_keys: [ "xai" ] }
    }

    assert_nil @account.reload.xai_api_key
  end

  test "confirmed member cannot replace account agent API keys" do
    @account.update!(openrouter_api_key: "owner-key")
    sign_in(users(:existing_user))

    patch account_agent_api_keys_path(@account), params: {
      account: {
        openrouter_api_key: "member-controlled-key",
        clear_ai_api_keys: [ "openrouter" ]
      }
    }

    assert_redirected_to account_path(@account)
    assert_equal "owner-key", @account.reload.openrouter_api_key
  end

end
