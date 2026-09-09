require "test_helper"

class Admin::AgentProviderSubscriptionUsagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @agent = agents(:other_account_agent)
    @agent.update!(model_id: "openai/gpt-5", runtime: "external")
  end

  test "site admins can read usage without account membership" do
    sign_in(users(:site_admin_user))
    client = Minitest::Mock.new
    client.expect(:usage, { status: "available", windows: [] }, provider: "openai", model: "gpt-5", refresh: false)
    AgentProviderAuthClient.stub(:new, client) do
      get admin_agent_provider_subscription_usage_path(@agent), as: :json
    end
    assert_response :success
    assert_equal "available", response.parsed_body["status"]
    client.verify
  end

  test "ordinary account members cannot use the admin endpoint" do
    sign_in(users(:user_1))
    AgentProviderAuthClient.stub(:new, ->(*) { flunk "must not contact runtime" }) do
      get admin_agent_provider_subscription_usage_path(@agent), as: :json
    end
    assert_redirected_to root_path
  end

  test "anonymous requests require authentication" do
    get admin_agent_provider_subscription_usage_path(@agent)
    assert_redirected_to login_path
  end
end
