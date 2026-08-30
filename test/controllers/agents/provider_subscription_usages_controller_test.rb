require "test_helper"

class Agents::ProviderSubscriptionUsagesControllerTest < ActionDispatch::IntegrationTest

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

end
