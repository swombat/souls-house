require "test_helper"

class Agents::ProvisioningRetriesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @agent.update!(
      runtime: "provisioning",
      health_state: "unhealthy",
      birth_committed_at: Time.current,
      provisioning_started_at: 1.hour.ago,
      sandbox_last_error: "Previous attempt failed",
      sandbox_last_error_at: 1.hour.ago,
      uuid: SecureRandom.uuid_v7
    )

    Setting.instance.update!(allow_agents: true)
    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
  end

  test "retry preserves the committed agent and queues provisioning again" do
    assert_no_difference [ "Agent.count", "ApiKey.count" ] do
      assert_enqueued_with(job: ProvisionAgentJob, args: [ @agent.id ]) do
        post account_agent_provisioning_retry_path(@account, @agent)
      end
    end

    @agent.reload
    assert_equal "provisioning", @agent.runtime
    assert_equal "unknown", @agent.health_state
    assert_nil @agent.sandbox_last_error
    assert_nil @agent.sandbox_last_error_at
    assert_redirected_to onboarding_account_agent_path(@account, @agent)
  end

end
