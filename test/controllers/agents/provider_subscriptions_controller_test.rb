require "test_helper"

class Agents::ProviderSubscriptionsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:team_account)
    @agent = agents(:other_account_agent)
    @agent.update!(
      model_id: "openai/gpt-5",
      runtime: "external",
      health_state: "healthy",
      trigger_bearer_token: "trigger-secret",
      endpoint_url: "https://agent.example.com"
    )
    Setting.instance.update!(allow_agents: true)
    sign_in(@user)
  end

  test "start relays the one-time code without storing it" do
    client = Object.new
    client.define_singleton_method(:start) do |provider:|
      {
        "status" => "pending",
        "provider" => provider,
        "verification_url" => "https://auth.example.com/device",
        "user_code" => "ABCD-EFGH",
        "expires_in" => 900
      }
    end

    AgentProviderAuthClient.stub(:new, client) do
      post account_agent_provider_subscription_path(@account, @agent),
           params: { provider: "openai" },
           as: :json
    end

    assert_response :success
    assert_equal "ABCD-EFGH", response.parsed_body.fetch("user_code")
    assert_equal "api_key", @agent.reload.provider_auth_mode("openai")
    assert_not_includes @agent.provider_connections.to_json, "ABCD-EFGH"
    assert_not_includes AuditLog.where(auditable: @agent).pluck(:data).to_json, "ABCD-EFGH"
  end

  test "Anthropic browser code is relayed without persistence or audit logging" do
    client = Object.new
    client.define_singleton_method(:submit_code) do |provider:, code:|
      raise "wrong provider" unless provider == "anthropic"
      raise "wrong code" unless code == "browser-secret"

      { "status" => "finalizing", "provider" => provider }
    end

    AgentProviderAuthClient.stub(:new, client) do
      post code_account_agent_provider_subscription_path(@account, @agent),
           params: { provider: "anthropic", code: "browser-secret" },
           as: :json
    end

    assert_response :success
    assert_equal "finalizing", response.parsed_body.fetch("status")
    assert_not_includes @agent.reload.provider_connections.to_json, "browser-secret"
    assert_not_includes AuditLog.where(auditable: @agent).pluck(:data).to_json, "browser-secret"
    assert_equal(
      "[FILTERED]",
      ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
        .filter("code" => "browser-secret")
        .fetch("code")
    )
  end

  test "status persists display metadata but no credentials" do
    client = Object.new
    client.define_singleton_method(:status) do |provider:|
      {
        "status" => "connected",
        "provider" => provider,
        "email" => "subscriber@example.com",
        "plan" => "Plus"
      }
    end

    AgentProviderAuthClient.stub(:new, client) do
      get account_agent_provider_subscription_path(@account, @agent),
          params: { provider: "openai" },
          as: :json
    end

    assert_response :success
    assert_equal "oauth_account", @agent.reload.provider_auth_mode("openai")
    assert_equal "subscriber@example.com", @agent.provider_connection("openai").fetch("email")
    assert_equal "Plus", @agent.provider_connection("openai").fetch("plan")
  end

  test "capabilities are read from the agent runtime" do
    client = Object.new
    client.define_singleton_method(:capabilities) do
      {
        "providers" => {
          "openai" => { "api_key" => true, "oauth_account" => true },
          "xai" => { "api_key" => true, "oauth_account" => true },
          "anthropic" => { "api_key" => true, "oauth_account" => true, "transport" => "clamp" },
          "gemini" => {
            "api_key" => true,
            "oauth_account" => true,
            "transport" => "antigravity",
            "experimental" => true
          }
        },
        "chaos_version" => "chaos 1.2.3"
      }
    end

    AgentProviderAuthClient.stub(:new, client) do
      get account_agent_provider_subscription_path(@account, @agent),
          params: { capabilities: true },
          as: :json
    end

    assert_response :success
    assert_equal true, response.parsed_body.dig("providers", "xai", "oauth_account")
    assert_equal "clamp", response.parsed_body.dig("providers", "anthropic", "transport")
    assert_equal "antigravity", response.parsed_body.dig("providers", "gemini", "transport")
    assert_equal "api_key", @agent.reload.provider_auth_mode("openai")
  end

  test "disconnect clears connection metadata" do
    @agent.record_provider_connection!("openai", status: "connected", email: "subscriber@example.com")
    client = Object.new
    client.define_singleton_method(:disconnect) { |provider:| { "status" => "none", "provider" => provider } }

    AgentProviderAuthClient.stub(:new, client) do
      delete account_agent_provider_subscription_path(@account, @agent),
             params: { provider: "openai" },
             as: :json
    end

    assert_response :success
    assert_equal "api_key", @agent.reload.provider_auth_mode("openai")
    assert_empty @agent.provider_connection("openai")
  end

  test "an expired login that comes back with no sign-in is recovered, not signed in" do
    @agent.record_provider_connection!("anthropic", status: "connected", plan: "Max")
    @agent.mark_provider_connection_status!("anthropic", "expired")

    2.times { get_status("anthropic", "connected") }

    assert_equal 0, provider_audits(Agent::PROVIDER_SIGNED_IN).count
    assert_equal 1, provider_audits(Agent::PROVIDER_RECOVERED).count
    assert_equal "connected", @agent.reload.provider_connection("anthropic")["status"]
  end

  test "a sign-in while the house still says connected is recorded once, after Connect" do
    @agent.record_provider_connection!("anthropic", status: "connected", plan: "Max")

    start_sign_in("anthropic")
    assert_equal 1, provider_audits(Agent::PROVIDER_SIGN_IN_STARTED).count
    2.times { get_status("anthropic", "connected") }

    rows = provider_audits(Agent::PROVIDER_SIGNED_IN)
    assert_equal 1, rows.count
    assert_equal({ "provider" => "anthropic", "plan" => "Max", "previous_status" => "connected" }, rows.last.data)
    assert_equal 0, provider_audits(Agent::PROVIDER_RECOVERED).count
  end

  test "a cancelled sign-in does not turn a later recovery into a sign-in" do
    @agent.record_provider_connection!("anthropic", status: "connected")
    @agent.mark_provider_connection_status!("anthropic", "expired")

    start_sign_in("anthropic")
    client = Object.new
    client.define_singleton_method(:cancel) { |provider:| { "status" => "none", "provider" => provider } }
    AgentProviderAuthClient.stub(:new, client) do
      post cancel_account_agent_provider_subscription_path(@account, @agent), params: { provider: "anthropic" }, as: :json
    end
    assert_response :success
    get_status("anthropic", "connected")

    assert_equal 1, provider_audits(Agent::PROVIDER_SIGN_IN_ENDED).count
    assert_equal 0, provider_audits(Agent::PROVIDER_SIGNED_IN).count
    assert_equal 1, provider_audits(Agent::PROVIDER_RECOVERED).count
  end

  private

  def provider_audits(action)
    AuditLog.where(auditable: @agent, action:)
  end

  def start_sign_in(provider)
    client = Object.new
    client.define_singleton_method(:start) { |provider:| { "status" => "pending", "provider" => provider } }
    AgentProviderAuthClient.stub(:new, client) do
      post account_agent_provider_subscription_path(@account, @agent), params: { provider: }, as: :json
    end
    assert_response :success
  end

  def get_status(provider, status)
    client = Object.new
    client.define_singleton_method(:status) { |provider:| { "status" => status, "provider" => provider, "plan" => "Max" } }
    AgentProviderAuthClient.stub(:new, client) do
      get account_agent_provider_subscription_path(@account, @agent), params: { provider: }, as: :json
    end
    assert_response :success
  end

end
