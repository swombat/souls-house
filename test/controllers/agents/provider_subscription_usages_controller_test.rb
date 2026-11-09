require "test_helper"

class Agents::ProviderSubscriptionUsagesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:team_account)
    @agent = agents(:other_account_agent)
    @agent.update!(
      model_id: "openai/gpt-5",
      provider_auth_modes: { "openai" => "oauth_account" },
      runtime: "external",
      health_state: "healthy",
      trigger_bearer_token: "trigger-secret",
      endpoint_url: "https://agent.example.com"
    )
    Setting.instance.update!(allow_agents: true)
    sign_in(@user)
  end

  test "returns normalized runtime usage" do
    client = Object.new
    client.define_singleton_method(:usage) do |provider:, model:, refresh:|
      raise "wrong provider" unless provider == "openai"
      raise "wrong model" unless model == "gpt-5"
      raise "unexpected refresh" if refresh

      {
        "provider" => provider,
        "status" => "available",
        "windows" => [
          {
            "id" => "session",
            "label" => "Session",
            "remaining_percent" => 72,
            "blocking" => true
          }
        ]
      }
    end

    AgentProviderAuthClient.stub(:new, client) do
      get account_agent_provider_subscription_usage_path(@account, @agent), as: :json
    end

    assert_response :success
    assert_equal 72, response.parsed_body.dig("windows", 0, "remaining_percent")
  end

  test "allows confirmed account members to view resident usage" do
    sign_in(users(:existing_user))
    client = Object.new
    client.define_singleton_method(:usage) do |provider:, model:, refresh:|
      {
        "provider" => provider,
        "status" => "available",
        "windows" => []
      }
    end

    AgentProviderAuthClient.stub(:new, client) do
      get account_agent_provider_subscription_usage_path(@account, @agent), as: :json
    end

    assert_response :success
  end

  test "shows a guest resident's usage in the account it visits" do
    visited = accounts(:personal_account)
    visited.guest_memberships.create!(agent: @agent, added_by: @user)
    client = Object.new
    client.define_singleton_method(:usage) do |provider:, model:, refresh:|
      { "provider" => provider, "status" => "available", "windows" => [ { "id" => "session", "remaining_percent" => 41 } ] }
    end

    AgentProviderAuthClient.stub(:new, client) do
      get account_agent_provider_subscription_usage_path(visited, @agent), as: :json
    end

    assert_response :success
    assert_equal 41, response.parsed_body.dig("windows", 0, "remaining_percent")
  end

  test "does not show usage for a resident that is not present in the account" do
    get account_agent_provider_subscription_usage_path(accounts(:personal_account), @agent), as: :json

    assert_response :not_found
  end

  test "a second look within a minute is served from the kept reading" do
    calls = 0
    client = Object.new
    client.define_singleton_method(:usage) do |provider:, model:, refresh:|
      calls += 1
      { "provider" => provider, "status" => "available", "windows" => [ { "id" => "session", "remaining_percent" => 55 } ] }
    end

    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      AgentProviderAuthClient.stub(:new, client) do
        2.times { get account_agent_provider_subscription_usage_path(@account, @agent), as: :json }
      end
    end

    assert_response :success
    assert_equal 1, calls
    assert_equal false, response.parsed_body["stale"]
    assert_equal 55, response.parsed_body.dig("windows", 0, "remaining_percent")
  end

end
