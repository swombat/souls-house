require "test_helper"

# The step a new integration lands on (YgDZGe).
class Accounts::ServiceConnectionAccessesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    sign_in @user
  end

  def tailscale
    post account_service_connections_path(@account), params: { provider: "tailscale", management_scope: "personal" }
    @account.service_connections.where(provider: "tailscale").sole
  end

  test "a new connection nobody can use lands on choosing residents, with the card's switches" do
    connection = tailscale
    assert_redirected_to account_service_connection_access_path(@account, connection.public_id)

    get account_service_connection_access_path(@account, connection.public_id)
    assert_response :success
    assert_equal "accounts/connection_access", inertia_component
    props = inertia_shared_props
    assert_equal connection.public_id, props.dig("connection", "id")
    assert_equal account_integrations_path(@account), props.fetch("integrations_url")
    residents = props.dig("connection", "residents")
    assert_includes residents.map { |resident| resident.fetch("name") }, agents(:research_assistant).name
    assert residents.none? { |resident| resident.fetch("enabled") }
    assert residents.all? { |resident| resident.fetch("access_update_url").present? }
  end

  test "a connection that already reaches a resident goes back to Integrations" do
    connection = @account.service_connections.create!(
      connected_by_user: @user, provider: "tailscale", external_subject_id: "ts-pre", management_scope: "personal",
      credential_kind: "none", credential_payload_hash: {}, credential_metadata: { "join" => "sign_in" }
    )
    agents(:research_assistant).agent_service_accesses.create!(service_connection: connection, enabled: true)

    probe = Class.new do
      include Rails.application.routes.url_helpers
      include IntegrationConnectionProps
      public :after_connect_path
    end.new
    assert_equal "/fallback", probe.after_connect_path(connection, "/fallback")

    connection.agent_service_accesses.update_all(enabled: false)
    assert_equal account_service_connection_access_path(@account, connection.public_id),
                 probe.after_connect_path(connection.reload, "/fallback")
  end

  test "an account with no residents yet goes back to Integrations" do
    account = Account.create!(name: "Empty house", account_type: "team")
    connection = account.service_connections.create!(
      connected_by_user: @user, provider: "tailscale", external_subject_id: "ts-empty", management_scope: "personal",
      credential_kind: "none", credential_payload_hash: {}, credential_metadata: { "join" => "sign_in" }
    )
    probe = Class.new do
      include Rails.application.routes.url_helpers
      include IntegrationConnectionProps
      public :after_connect_path
    end.new
    assert_equal "/fallback", probe.after_connect_path(connection, "/fallback")
  end

  test "another member's personal connection is not shown" do
    connection = tailscale
    connection.update!(connected_by_user: users(:existing_user))
    get account_service_connection_access_path(@account, connection.public_id)
    assert_response :not_found
  end

end
