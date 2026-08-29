require "test_helper"

class Accounts::PersonalServicesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @connection = @account.service_connections.create!(
      connected_by_user: @user,
      provider: "github",
      external_subject_id: "github-user-personal-services",
      external_identity: "owner",
      label: "owner/repository",
      management_scope: "personal",
      credential_kind: "token",
      credential_fingerprint: "personal-services-fingerprint",
      credential_payload_hash: { "token" => "github_pat_test" },
      credential_metadata: {
        "credential_strategy" => "static",
        "repository" => "owner/repository"
      }
    )
    @enabled_agent = agents(:research_assistant)
    @disabled_agent = agents(:code_reviewer)
    @enabled_agent.agent_service_accesses.create!(
      service_connection: @connection,
      enabled: true,
      provisioning_status: "provisioned"
    )
    sign_in @user
  end

  test "lists resident access for every personal service connection" do
    get account_personal_services_path(@account)

    assert_response :success
    connection = inertia_shared_props.fetch("connections").find { |item| item.fetch("id") == @connection.public_id }
    residents = connection.fetch("residents")
    enabled = residents.find { |resident| resident.fetch("id") == @enabled_agent.to_param }
    disabled = residents.find { |resident| resident.fetch("id") == @disabled_agent.to_param }

    assert_equal true, enabled.fetch("enabled")
    assert_equal "provisioned", enabled.fetch("provisioning_status")
    assert_equal false, disabled.fetch("enabled")
    assert_equal(
      account_agent_service_access_path(@account, @enabled_agent, @connection.public_id),
      enabled.fetch("access_update_url")
    )
  end

end
