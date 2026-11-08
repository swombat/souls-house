require "test_helper"
require "webmock/minitest"

class GoogleReconnectTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    sign_in @user
  end

  test "fresh Connect restores the disconnected connection and preserves resident access" do
    connection = google_connection
    enabled = connection.agent_service_accesses.create!(agent: agents(:research_assistant), enabled: true)
    disabled = connection.agent_service_accesses.create!(agent: agents(:code_reviewer), enabled: false)
    before_access = connection.agent_service_accesses.order(:id).pluck(:id, :agent_id, :enabled)
    revision = connection.credential_revision

    assert_no_difference [ "ServiceConnection.count", "AgentServiceAccess.count" ] do
      complete_connect
    end

    assert_redirected_to account_integrations_path(@account)
    assert_match(/connected/, flash[:notice])
    assert_equal "connected", connection.reload.status
    assert_equal "replacement-refresh", connection.credential_payload_hash["refresh_token"]
    assert_equal revision + 1, connection.credential_revision
    assert_equal "My Google", connection.label
    assert_equal @user.id, connection.connected_by_user_id
    assert_equal "personal", connection.management_scope
    assert_equal before_access, connection.agent_service_accesses.order(:id).pluck(:id, :agent_id, :enabled)
    assert enabled.reload.enabled?
    assert_not disabled.reload.enabled?
    assert_not connection.enabled_for_new_agents?
    assert_not connection.freely_provisionable?
    assert ServiceAuthorizationAttempt.order(:id).last.consumed_at?
  end

  test "explicit reconnect after rejected refresh restores the same row and preserves grants" do
    connection = google_connection(status: "connected", credential_payload_hash: {
      "refresh_token" => "rejected-refresh", "access_token" => "expired",
      "expires_at" => 1.minute.ago.iso8601
    })
    connection.agent_service_accesses.create!(agent: agents(:research_assistant), enabled: true)
    connection.agent_service_accesses.create!(agent: agents(:code_reviewer), enabled: false)
    grants = connection.agent_service_accesses.order(:id).pluck(:id, :enabled)
    definition = Services::Definition.fetch("google_workspace")
    adapter = definition.adapter
    credentials = Object.new
    credentials.define_singleton_method(:dig) { |*| "synthetic-credential" }
    stub_request(:post, Services::GoogleWorkspaceAdapter::TOKEN_URL)
      .to_return(status: 400, body: { error: "invalid_grant" }.to_json)
    Rails.application.stub(:credentials, credentials) do
      assert_raises(Services::GoogleWorkspaceAdapter::ReauthorizationRequired) { adapter.current_access_token(connection) }
    end
    assert_equal "reauthorizing", connection.reload.status

    assert_no_difference [ "ServiceConnection.count", "AgentServiceAccess.count" ] do
      complete_connect(service_connection: connection)
    end
    assert_redirected_to account_integrations_path(@account)
    assert_equal "connected", connection.reload.status
    assert_equal "replacement-refresh", connection.credential_payload_hash["refresh_token"]
    assert_equal grants, connection.agent_service_accesses.order(:id).pluck(:id, :enabled)
    assert_requested :post, Services::GoogleWorkspaceAdapter::TOKEN_URL, times: 1
    assert_not_requested :post, Services::GoogleWorkspaceAdapter::REVOKE_URL
  end

  test "fresh Connect also restores account-managed ownership without changing it" do
    @account = accounts(:team_account)
    connection = google_connection(management_scope: "account_managed")

    assert_no_difference "ServiceConnection.count" do
      complete_connect(management_scope: "account_managed")
    end

    assert_equal "connected", connection.reload.status
    assert_equal "account_managed", connection.management_scope
  end

  %w[connected reauthorizing suspended error].each do |status|
    test "fresh Connect does not overwrite a #{status} Google connection" do
      connection = google_connection(status: status)
      before_attributes = connection.attributes

      assert_no_difference "ServiceConnection.count" do
        complete_connect
      end

      assert_match(/already connected; edit its access instead/, flash[:alert])
      assert_equal before_attributes, connection.reload.attributes
    end
  end

  test "fresh Connect cannot take another member's disconnected Google identity" do
    connection = google_connection(connected_by_user: users(:existing_user))
    before_attributes = connection.attributes

    assert_no_difference "ServiceConnection.count" do
      complete_connect
    end

    assert_match(/another account member/, flash[:alert])
    assert_equal before_attributes, connection.reload.attributes
  end

  test "fresh Connect cannot turn a personal connection into account-managed access" do
    @account = accounts(:team_account)
    connection = google_connection
    before_attributes = connection.attributes

    complete_connect(management_scope: "account_managed")

    assert_match(/ownership does not match/, flash[:alert])
    assert_equal before_attributes, connection.reload.attributes
  end

  test "fresh Connect cannot turn an account-managed connection into personal access" do
    @account = accounts(:team_account)
    connection = google_connection(management_scope: "account_managed")
    before_attributes = connection.attributes

    complete_connect

    assert_match(/ownership does not match/, flash[:alert])
    assert_equal before_attributes, connection.reload.attributes
  end

  test "fresh Connect refuses cleanly if account management rights are lost during OAuth" do
    @account = accounts(:team_account)
    connection = google_connection(management_scope: "account_managed")
    before_attributes = connection.attributes

    assert_no_difference "ServiceConnection.count" do
      complete_connect(management_scope: "account_managed") do
        memberships(:team_account_owner).update_columns(role: "member")
      end
    end

    assert_redirected_to account_integrations_path(@account)
    assert_match(/can no longer manage/, flash[:alert])
    assert_equal before_attributes, connection.reload.attributes
  end

  test "fresh Connect matches provider subject rather than email" do
    connection = google_connection(external_subject_id: "different-google-subject")

    assert_difference "ServiceConnection.count", 1 do
      complete_connect
    end

    assert_equal "revoked", connection.reload.status
    assert_equal "connected", @account.service_connections.find_by!(external_subject_id: "google-subject").status
  end

  test "fresh Connect does not revive a matching identity in another account" do
    connection = google_connection(account: accounts(:team_account))

    assert_difference "ServiceConnection.count", 1 do
      complete_connect
    end

    assert_equal "revoked", connection.reload.status
    assert_equal "connected", @account.service_connections.find_by!(external_subject_id: "google-subject").status
  end

  private

  def google_connection(**attributes)
    ServiceConnection.create!({
      account: @account,
      connected_by_user: @user,
      provider: "google_workspace",
      external_subject_id: "google-subject",
      external_identity: "person@example.test",
      label: "My Google",
      management_scope: "personal",
      credential_kind: "oauth2",
      status: "revoked",
      enabled_for_new_agents: false,
      freely_provisionable: false,
      credential_metadata: {
        "credential_strategy" => "refresh_broker",
        "granted_scopes" => Services::Catalog::GOOGLE_WORKSPACE_READ
      }
    }.merge(attributes))
  end

  def complete_connect(management_scope: "personal", service_connection: nil)
    definition = Services::Definition.fetch("google_workspace")
    adapter = definition.adapter
    adapter.stub(:authorization_url, ->(_attempt, state:, redirect_uri:) {
      "https://accounts.google.test/authorize?state=#{state}"
    }) do
      definition.stub(:adapter, adapter) do
        post account_service_authorizations_path(@account), params: {
          provider: "google_workspace", management_scope: management_scope, access_profile: "read_only",
          service_connection_id: service_connection&.public_id
        }
      end
    end
    assert_response :redirect
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    attempt = ServiceAuthorizationAttempt.order(:id).last
    if service_connection
      assert_equal service_connection.id, attempt.service_connection_id
    else
      assert_nil attempt.service_connection_id
    end
    yield if block_given?
    result = {
      external_subject_id: "google-subject",
      external_identity: "person@example.test",
      credential_kind: "oauth2",
      credential_payload: { "refresh_token" => "replacement-refresh" },
      credential_metadata: {
        "credential_strategy" => "refresh_broker",
        "granted_scopes" => Services::Catalog::GOOGLE_WORKSPACE_READ
      }
    }
    adapter.stub(:exchange_code, result) do
      definition.stub(:adapter, adapter) do
        get service_authorization_callback_path, params: { state: state, code: "synthetic-code" }
      end
    end
  end

end
