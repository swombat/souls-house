require "test_helper"

class Agents::OrientationRetriesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @agent.update!(
      runtime: "external",
      health_state: "healthy",
      birth_committed_at: Time.current,
      orientation_requested_at: 1.hour.ago,
      orientation_last_error: "Previous attempt failed",
      orientation_last_error_at: 1.hour.ago,
      uuid: SecureRandom.uuid_v7
    )

    Setting.instance.update!(allow_agents: true)
    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
  end

  test "retry clears the previous failure and queues a new orientation" do
    assert_enqueued_with(job: OrientNewAgentJob, args: [ @agent.id ]) do
      post account_agent_orientation_retry_path(@account, @agent)
    end

    @agent.reload
    assert_nil @agent.orientation_completed_at
    assert_nil @agent.orientation_last_error
    assert_nil @agent.orientation_last_error_at
    assert_redirected_to onboarding_account_agent_path(@account, @agent)
  end

  test "retry refuses while the runtime is unhealthy and keeps the old error" do
    @agent.update!(health_state: "unhealthy")

    assert_no_enqueued_jobs only: OrientNewAgentJob do
      post account_agent_orientation_retry_path(@account, @agent)
    end

    assert_redirected_to onboarding_account_agent_path(@account, @agent)
    assert_match "must be healthy", flash[:alert]
    assert_equal "Previous attempt failed", @agent.reload.orientation_last_error
  end

end
