require "test_helper"
require "webmock/minitest"

class FreeagentConnectionTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @credentials = { freeagent: { client_id: "house-client", client_secret: "private-client-secret" } }
    sign_in @user
  end

  test "browser authorization creates an encrypted company connection without bookkeeping writes" do
    Rails.application.stub(:credentials, @credentials) do
      post account_service_authorizations_path(@account), params: {
        provider: "freeagent", management_scope: "personal"
      }
    end
    assert_response :redirect
    uri = URI(response.location)
    query = Rack::Utils.parse_query(uri.query)
    assert_equal "api.freeagent.com", uri.host
    assert_equal "/v2/approve_app", uri.path
    assert_equal service_authorization_callback_url, query.fetch("redirect_uri")
    assert_not query.key?("scope")
    assert_not query.key?("client_secret")
    attempt = ServiceAuthorizationAttempt.order(:id).last
    assert_empty attempt.requested_scopes

    stub_exchange
    Rails.application.stub(:credentials, @credentials) do
      assert_difference "ServiceConnection.count", 1 do
        get service_authorization_callback_path, params: { state: query.fetch("state"), code: "approved-code" }
      end
    end
    assert_redirected_to account_integrations_path(@account)
    assert attempt.reload.consumed_at.present?
    connection = @account.service_connections.find_by!(provider: "freeagent")
    assert_equal "connected", connection.status
    assert_equal "refresh_broker", connection.credential_strategy
    assert_includes connection.external_identity, "Example Ltd"
    assert_includes connection.external_identity, "12345678"
    assert_includes connection.external_identity, "owner@example.test"
    assert_equal "private-refresh", connection.credential_payload_hash.fetch("refresh_token")
    stored = connection.read_attribute_before_type_cast(:credential_payload)
    assert_not_includes stored, "private-refresh"
    assert_not_includes stored, "current-access"
    assert_requested :post, "https://api.freeagent.com/v2/token_endpoint", times: 1
    assert_not_requested :post, %r{api\.freeagent\.com/v2/(?!token_endpoint)}

    # Callback state is single-use; a replay cannot create another connection.
    assert_no_difference "ServiceConnection.count" do
      get service_authorization_callback_path, params: { state: query.fetch("state"), code: "approved-code" }
    end
    assert_redirected_to root_path
  end

  test "broker gives only access tokens to explicitly enabled residents" do
    connection = connected_company
    key = ApiKey.generate_for(@user, name: "FreeAgent test", agent: @agent)
    headers = { "Authorization" => "Bearer #{key.raw_token}" }
    endpoint = api_v1_service_connection_access_token_url(connection.public_id)
    get endpoint, headers: headers
    assert_response :not_found

    access = @agent.agent_service_accesses.create!(service_connection: connection, enabled: true)
    get endpoint, headers: headers
    assert_response :ok
    assert_equal %w[access_token expires_at], response.parsed_body.keys.sort
    assert_equal "current-access", response.parsed_body.fetch("access_token")
    assert_not_includes response.body, "private-refresh"
    assert_not_includes response.body, "private-client-secret"

    manifest = connection.runtime_entry(agent: @agent)
    assert_equal "refresh_broker", manifest.fetch("credential_strategy")
    assert_equal [ "access_token_endpoint" ], manifest.fetch("credentials").keys
    assert_not_includes manifest.to_json, "private-refresh"
    assert_not_includes manifest.to_json, "current-access"

    access.update!(enabled: false)
    get endpoint, headers: headers
    assert_response :not_found
    access.update!(enabled: true)
    connection.update!(status: "reauthorizing")
    get endpoint, headers: headers
    assert_response :conflict
  end

  test "human and foreign resident keys cannot obtain the company's token" do
    connection = connected_company
    human = ApiKey.generate_for(@user, name: "Human key")
    get api_v1_service_connection_access_token_url(connection.public_id),
      headers: { "Authorization" => "Bearer #{human.raw_token}" }
    assert_response :forbidden

    foreign_agent = agents(:other_account_agent)
    foreign_key = ApiKey.generate_for(@user, name: "Foreign key", agent: foreign_agent)
    get api_v1_service_connection_access_token_url(connection.public_id),
      headers: { "Authorization" => "Bearer #{foreign_key.raw_token}" }
    assert_response :not_found
  end

  test "disconnect clears credentials and broker access without calling an invented revoke endpoint" do
    connection = connected_company
    @agent.agent_service_accesses.create!(service_connection: connection, enabled: true)
    connection.disconnect!
    assert_equal "revoked", connection.reload.status
    assert_empty connection.credential_payload_hash
    key = ApiKey.generate_for(@user, name: "Revoked connection", agent: @agent)
    get api_v1_service_connection_access_token_url(connection.public_id),
      headers: { "Authorization" => "Bearer #{key.raw_token}" }
    assert_response :conflict
    assert_not_requested :any, %r{api\.freeagent\.com}
  end

  private

  def connected_company
    @account.service_connections.create!(
      connected_by_user: @user, provider: "freeagent",
      external_subject_id: "company-and-user", external_identity: "Example Ltd",
      management_scope: "personal", credential_kind: "oauth2", status: "connected",
      credential_payload_hash: {
        "access_token" => "current-access", "refresh_token" => "private-refresh",
        "expires_at" => 30.minutes.from_now.utc.iso8601
      },
      credential_metadata: { "credential_strategy" => "refresh_broker" }
    )
  end

  def stub_exchange
    stub_request(:post, "https://api.freeagent.com/v2/token_endpoint")
      .with(basic_auth: %w[house-client private-client-secret],
        body: hash_including("code" => "approved-code", "grant_type" => "authorization_code"))
      .to_return(status: 200, body: {
        access_token: "current-access", refresh_token: "private-refresh",
        expires_in: 3600, refresh_token_expires_in: 86_400
      }.to_json)
    stub_request(:get, "https://api.freeagent.com/v2/users/me")
      .with(headers: { "Authorization" => "Bearer current-access" })
      .to_return(status: 200, body: {
        user: { url: "https://api.freeagent.com/v2/users/123", email: "owner@example.test",
          permission_level: 8, ni_number: "DO-NOT-STORE" }
      }.to_json)
    stub_request(:get, "https://api.freeagent.com/v2/company")
      .with(headers: { "Authorization" => "Bearer current-access" })
      .to_return(status: 200, body: {
        company: { id: 456, url: "https://api.freeagent.com/v2/company", name: "Example Ltd",
          company_registration_number: "12345678", sales_tax_registration_number: "DO-NOT-STORE" }
      }.to_json)
  end

end
