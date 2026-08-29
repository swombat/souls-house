require "test_helper"

class ServiceAuthorizationsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    sign_in @user
  end

  test "starts Dropbox authorization with PKCE and no confidential credentials" do
    assert_difference "ServiceAuthorizationAttempt.count", 1 do
      post account_service_authorizations_path(@account), params: {
        provider: "dropbox",
        management_scope: "personal",
        access_profile: "full_sharing"
      }
    end

    assert_response :redirect
    uri = URI(response.location)
    query = Rack::Utils.parse_query(uri.query)
    attempt = ServiceAuthorizationAttempt.order(:id).last

    assert_equal "www.dropbox.com", uri.host
    assert_equal "/oauth2/authorize", uri.path
    assert_equal "code", query.fetch("response_type")
    assert_equal "offline", query.fetch("token_access_type")
    assert_equal "S256", query.fetch("code_challenge_method")
    assert query.fetch("code_challenge").present?
    assert query.fetch("state").present?
    assert_equal attempt.requested_scopes.sort, query.fetch("scope").split.sort
    assert_equal ServiceAuthorizationAttempt.digest(query.fetch("state")), attempt.state_digest
    assert_equal service_authorization_callback_url, query.fetch("redirect_uri")
    assert_not query.key?("client_secret")
    assert_not query.key?("access_token")
  end

  test "callback rejects authorization state started by another signed-in user" do
    _attempt, state = ServiceAuthorizationAttempt.begin!(
      account: @account,
      user: users(:existing_user),
      provider: "dropbox",
      management_scope: "personal",
      access_profile: "read_only",
      return_path: account_personal_services_path(@account)
    )

    assert_no_difference "ServiceConnection.count" do
      get service_authorization_callback_path, params: { state: state, code: "provider-code" }
    end

    assert_redirected_to root_path
  end

  test "starts Google Workspace authorization with offline access and PKCE" do
    original_client_id = ENV["GOOGLE_WORKSPACE_CLIENT_ID"]
    ENV["GOOGLE_WORKSPACE_CLIENT_ID"] = "google-client-id"
    begin
      post account_service_authorizations_path(@account), params: {
        provider: "google_workspace",
        management_scope: "personal",
        access_profile: "read_only"
      }
    ensure
      ENV["GOOGLE_WORKSPACE_CLIENT_ID"] = original_client_id
    end

    assert_response :redirect
    uri = URI(response.location)
    query = Rack::Utils.parse_query(uri.query)
    attempt = ServiceAuthorizationAttempt.order(:id).last

    assert_equal "accounts.google.com", uri.host
    assert_equal "/o/oauth2/v2/auth", uri.path
    assert_equal "offline", query.fetch("access_type")
    assert_equal "consent", query.fetch("prompt")
    assert_equal "S256", query.fetch("code_challenge_method")
    assert_equal attempt.requested_scopes.sort, query.fetch("scope").split.sort
    assert_equal service_authorization_callback_url, query.fetch("redirect_uri")
    assert_not query.key?("client_secret")
  end

  test "starts Google authorization from a validated granular authority selection" do
    original_client_id = ENV["GOOGLE_WORKSPACE_CLIENT_ID"]
    ENV["GOOGLE_WORKSPACE_CLIENT_ID"] = "google-client-id"
    selection = {
      drive: "write",
      docs: "write",
      sheets: "write",
      slides: "write",
      calendar: "read",
      gmail: "none",
      meet: "none"
    }
    begin
      post account_service_authorizations_path(@account), params: {
        provider: "google_workspace",
        management_scope: "personal",
        authority_selection: JSON.generate(selection)
      }
    ensure
      ENV["GOOGLE_WORKSPACE_CLIENT_ID"] = original_client_id
    end

    assert_response :redirect
    attempt = ServiceAuthorizationAttempt.order(:id).last
    assert_nil attempt.access_profile
    assert_equal selection.stringify_keys, attempt.authority_selection
    assert_not attempt.requested_scopes.any? { |scope| scope.include?("gmail") }
    assert_not attempt.requested_scopes.any? { |scope| scope.include?("meetings.space") }
  end

  test "rejects forged Google authority options" do
    assert_no_difference "ServiceAuthorizationAttempt.count" do
      post account_service_authorizations_path(@account), params: {
        provider: "google_workspace",
        management_scope: "personal",
        authority_selection: JSON.generate(
          drive: "admin", docs: "none", sheets: "none", slides: "none",
          calendar: "none", gmail: "none", meet: "none"
        )
      }
    end

    assert_redirected_to account_personal_services_path(@account)
    assert_match(/Unsupported Drive authority/, flash[:alert])
  end

  test "editing Google authority revokes first and keeps the connection identity" do
    connection = @account.service_connections.create!(
      connected_by_user: @user,
      provider: "google_workspace",
      external_subject_id: "google-user-edit",
      management_scope: "personal",
      credential_kind: "oauth2",
      credential_payload_hash: {
        "access_token" => "old-access",
        "refresh_token" => "old-refresh",
        "expires_at" => 1.hour.from_now.utc.iso8601
      },
      credential_metadata: {
        "credential_strategy" => "refresh_broker",
        "granted_scopes" => Services::Catalog::GOOGLE_WORKSPACE_READ
      }
    )
    revoked = false
    adapter = Object.new
    adapter.define_singleton_method(:revoke!) { |candidate| revoked = candidate == connection }
    adapter.define_singleton_method(:authorization_url) do |_attempt, state:, redirect_uri:|
      "https://accounts.google.test/authorize?state=#{state}&redirect_uri=#{CGI.escape(redirect_uri)}"
    end
    definition = Services::Definition.fetch("google_workspace")

    definition.stub(:adapter, adapter) do
      post account_service_authorizations_path(@account), params: {
        provider: "google_workspace",
        management_scope: "personal",
        service_connection_id: connection.public_id,
        authority_selection: JSON.generate(
          drive: "none", docs: "none", sheets: "write", slides: "none",
          calendar: "read", gmail: "none", meet: "none"
        )
      }
    end

    assert_response :redirect
    assert revoked
    assert_equal "reauthorizing", connection.reload.status
    assert_empty connection.credential_payload_hash
    attempt = ServiceAuthorizationAttempt.order(:id).last
    assert_equal connection, attempt.service_connection
    assert_equal "write", attempt.authority_selection["sheets"]
  end

  test "Google callback cannot overwrite an existing identity outside the edit flow" do
    connection = @account.service_connections.create!(
      connected_by_user: @user,
      provider: "google_workspace",
      external_subject_id: "google-user-existing",
      external_identity: "person@example.test",
      management_scope: "personal",
      credential_kind: "oauth2",
      credential_payload_hash: { "refresh_token" => "existing-refresh" },
      credential_metadata: {
        "credential_strategy" => "refresh_broker",
        "granted_scopes" => Services::Catalog::GOOGLE_WORKSPACE_READ
      }
    )
    _attempt, state = ServiceAuthorizationAttempt.begin!(
      account: @account,
      user: @user,
      provider: "google_workspace",
      management_scope: "personal",
      authority_selection: {
        drive: "read", docs: "read", sheets: "read", slides: "read",
        calendar: "none", gmail: "none", meet: "none"
      },
      return_path: account_personal_services_path(@account)
    )
    adapter = Object.new
    adapter.define_singleton_method(:exchange_code) do |code:, attempt:, redirect_uri:|
      raise "unexpected code" unless code == "provider-code"
      raise "unexpected provider" unless attempt.provider == "google_workspace"
      raise "unexpected redirect" unless redirect_uri.end_with?("/service_authorizations/callback")

      {
        external_subject_id: "google-user-existing",
        external_identity: "person@example.test",
        credential_kind: "oauth2",
        credential_payload: { "refresh_token" => "replacement-refresh" },
        credential_metadata: {
          "credential_strategy" => "refresh_broker",
          "granted_scopes" => Services::Catalog::GOOGLE_WORKSPACE_READ
        }
      }
    end
    definition = Services::Definition.fetch("google_workspace")

    definition.stub(:adapter, adapter) do
      get service_authorization_callback_path, params: { state: state, code: "provider-code" }
    end

    assert_redirected_to account_personal_services_path(@account)
    assert_match(/already connected; edit its access instead/, flash[:alert])
    assert_equal "existing-refresh", connection.reload.credential_payload_hash["refresh_token"]
  end

  test "starts Oura authorization through the generic service callback" do
    post account_service_authorizations_path(@account), params: {
      provider: "oura",
      management_scope: "personal",
      access_profile: "health_read"
    }

    assert_response :redirect
    uri = URI(response.location)
    query = Rack::Utils.parse_query(uri.query)

    assert_equal "cloud.ouraring.com", uri.host
    assert_equal service_authorization_callback_url, query["redirect_uri"]
    assert_equal OuraApi::SCOPES.sort, query["scope"].split.sort
  end

  test "Oura callback persists tokens directly in a service connection" do
    _attempt, state = ServiceAuthorizationAttempt.begin!(
      account: @account,
      user: @user,
      provider: "oura",
      management_scope: "personal",
      access_profile: "health_read",
      return_path: account_personal_services_path(@account)
    )
    adapter = Object.new
    result = {
      external_subject_id: "oura-123",
      external_identity: "oura-person@example.test",
      match_existing_by: :connected_user,
      credential_kind: "oauth2",
      credential_payload: {
        "access_token" => "oura-access",
        "refresh_token" => "oura-refresh",
        "expires_at" => 2.days.from_now.utc.iso8601
      },
      credential_metadata: {
        "granted_scopes" => OuraApi::SCOPES,
        "credential_strategy" => "refresh_broker"
      }
    }
    expected_redirect_uri = service_authorization_callback_url
    adapter.define_singleton_method(:exchange_code) do |code:, attempt:, redirect_uri:|
      raise "unexpected code" unless code == "provider-code"
      raise "unexpected attempt" unless attempt.provider == "oura"
      raise "unexpected redirect" unless redirect_uri == expected_redirect_uri
      result
    end
    definition = Services::Definition.fetch("oura")

    assert_difference "ServiceConnection.where(provider: 'oura').count", 1 do
      definition.stub :adapter, adapter do
        get service_authorization_callback_path, params: { state: state, code: "provider-code" }
      end
    end

    connection = @account.service_connections.find_by!(provider: "oura")
    assert_equal "oura-refresh", connection.credential_payload_hash["refresh_token"]
    assert_nil @user.oura_integration
  end

end
