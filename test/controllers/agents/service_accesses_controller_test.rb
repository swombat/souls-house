require "test_helper"

class Agents::ServiceAccessesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @connection = @account.service_connections.create!(
      connected_by_user: @user,
      provider: "github",
      external_subject_id: "github-user-service-access",
      external_identity: "owner",
      label: "owner/repository",
      management_scope: "personal",
      credential_kind: "token",
      credential_fingerprint: "service-access-fingerprint",
      credential_payload_hash: { "token" => "github_pat_test" },
      credential_metadata: {
        "credential_strategy" => "static",
        "repository" => "owner/repository"
      }
    )
    sign_in @user
  end

  test "returns to personal services after changing resident access there" do
    assert_difference "AgentServiceAccess.enabled.count", 1 do
      patch account_agent_service_access_path(@account, @agent, @connection.public_id),
            params: { enabled: true },
            headers: { "HTTP_REFERER" => account_personal_services_url(@account) }
    end

    assert_redirected_to account_personal_services_path(@account)
  end

  test "does not enable access while a service is reauthorizing" do
    @connection.update!(status: "reauthorizing")

    assert_no_difference "AgentServiceAccess.enabled.count" do
      patch account_agent_service_access_path(@account, @agent, @connection.public_id),
            params: { enabled: true },
            headers: { "HTTP_REFERER" => account_personal_services_url(@account) }
    end

    assert_redirected_to account_personal_services_path(@account)
    assert_equal "Reconnect this service before enabling resident access", flash[:alert]
  end

end
