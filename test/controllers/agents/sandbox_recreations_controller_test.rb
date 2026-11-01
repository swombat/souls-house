require "test_helper"

class Agents::SandboxRecreationsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)

    Setting.instance.update!(allow_agents: true)
  end

  test "an owner restarting a hosted resident queues a forced reconcile" do
    sign_in(@user)
    @agent.update!(
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      container_name: "hk-agent-test",
      container_image: "helixkit-agent-runtime:latest",
      health_state: "healthy"
    )

    assert_enqueued_with(job: HostedAgentRuntimeReconcileJob, args: [ @agent.id, { force: true } ]) do
      post account_agent_sandbox_recreation_path(@account, @agent)
    end

    assert_redirected_to edit_account_agent_path(@account, @agent, tab: "settings")
    assert_match "Restarting", flash[:notice]
  end

  test "restart refuses a resident with no sandbox" do
    sign_in(@user)
    @agent.update!(runtime: "deprecated")

    assert_no_enqueued_jobs only: HostedAgentRuntimeReconcileJob do
      post account_agent_sandbox_recreation_path(@account, @agent)
    end

    assert_redirected_to edit_account_agent_path(@account, @agent, tab: "settings")
    assert_match "Only hosted residents", flash[:alert]
  end

  test "a plain member of the account cannot restart its resident" do
    member = users(:existing_user)
    account = accounts(:team_account)
    agent = agents(:other_account_agent)
    agent.update!(uuid: SecureRandom.uuid_v7, container_name: "hk-agent-team", health_state: "healthy")
    assert_equal "member", member.memberships.find_by!(account: account).role
    assert_not member.site_admin
    sign_in(member)

    assert_no_enqueued_jobs only: HostedAgentRuntimeReconcileJob do
      post account_agent_sandbox_recreation_path(account, agent), as: :json
    end

    assert_response :forbidden
  end

end
