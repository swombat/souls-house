require "test_helper"

class Accounts::IntegrationsControllerTest < ActionDispatch::IntegrationTest

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
    get account_integrations_path(@account)

    assert_response :success
    assert_equal "accounts/integrations", inertia_component
    assert_equal true, inertia_shared_props.fetch("can_manage_account")
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

  test "exposes one focused provider setup when requested" do
    get account_integrations_path(@account), params: { connect: "google_workspace" }

    assert_response :success
    assert_equal "google_workspace", inertia_shared_props.dig("focused_service", "key")
  end

  test "ignores an unknown focused provider" do
    get account_integrations_path(@account), params: { connect: "unknown" }

    assert_response :success
    assert_nil inertia_shared_props["focused_service"]
  end

  test "legacy personal services URL preserves focused provider" do
    get account_personal_services_path(@account), params: { connect: "google_workspace" }

    assert_redirected_to account_integrations_path(@account, connect: "google_workspace")
  end

  test "legacy account services URL redirects to integrations" do
    get account_services_path(@account)

    assert_redirected_to account_integrations_path(@account)
  end

  test "legacy account services URL preserves focused provider" do
    get account_services_path(@account), params: { connect: "dropbox" }

    assert_redirected_to account_integrations_path(@account, connect: "dropbox")
  end

  test "member sees own personal and account integrations but not another member's personal integrations" do
    account = accounts(:team_account)
    member = users(:existing_user)
    own = create_connection(account, member, "personal", "member-personal")
    shared = create_connection(account, @user, "account_managed", "shared-account")
    other = create_connection(account, @user, "personal", "owner-personal")
    sign_in member

    get account_integrations_path(account)

    assert_response :success
    props = inertia_shared_props
    assert_equal false, props.fetch("can_manage_account")
    connections = props.fetch("connections").index_by { |connection| connection.fetch("id") }
    assert_equal [ own.public_id, shared.public_id ].sort, connections.keys.sort
    assert_not connections.key?(other.public_id)
    assert_equal true, connections.fetch(own.public_id).fetch("can_manage")
    assert_equal true, connections.fetch(own.public_id).fetch("can_provision")
    assert_equal true, connections.fetch(own.public_id).fetch("can_delegate")
    assert_equal false, connections.fetch(shared.public_id).fetch("can_manage")
    assert_equal false, connections.fetch(shared.public_id).fetch("can_provision")
    assert_equal false, connections.fetch(shared.public_id).fetch("can_delegate")
  end

  test "admin sees own personal and account integrations without treating account credentials as personal delegation" do
    account = accounts(:team_account)
    own = create_connection(account, @user, "personal", "owner-personal")
    shared = create_connection(account, users(:existing_user), "account_managed", "shared-account")
    other = create_connection(account, users(:existing_user), "personal", "member-personal")

    get account_integrations_path(account)

    assert_response :success
    props = inertia_shared_props
    assert_equal true, props.fetch("can_manage_account")
    connections = props.fetch("connections").index_by { |connection| connection.fetch("id") }
    assert_equal [ own.public_id, shared.public_id ].sort, connections.keys.sort
    assert_not connections.key?(other.public_id)
    assert_equal true, connections.fetch(shared.public_id).fetch("can_manage")
    assert_equal true, connections.fetch(shared.public_id).fetch("can_provision")
    assert_equal false, connections.fetch(shared.public_id).fetch("can_delegate")
    assert props.fetch("services").any? { |service| service.fetch("management_scopes").include?("account_managed") }
  end

  private

  def create_connection(account, user, scope, subject)
    account.service_connections.create!(
      connected_by_user: user,
      provider: "dropbox",
      external_subject_id: subject,
      external_identity: "#{subject}@example.com",
      management_scope: scope,
      credential_kind: "oauth2",
      credential_payload_hash: { "access_token" => "test-only-token" },
      credential_metadata: { "credential_strategy" => "static" }
    )
  end

end
