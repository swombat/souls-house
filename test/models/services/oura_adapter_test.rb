require "test_helper"

class Services::OuraAdapterTest < ActiveSupport::TestCase

  setup do
    @definition = Services::Definition.fetch("oura")
    @adapter = Services::OuraAdapter.new(@definition)
    @attempt, = ServiceAuthorizationAttempt.begin!(
      account: accounts(:personal_account),
      user: users(:user_1),
      provider: "oura",
      management_scope: "personal",
      access_profile: "health_read",
      return_path: "/return"
    )
  end

  test "builds generic Oura authorization URL" do
    url = @adapter.stub(:client_id, "test-oura-client") do
      @adapter.authorization_url(
        @attempt,
        state: "state-value",
        redirect_uri: "https://example.test/service_authorizations/callback"
      )
    end
    query = Rack::Utils.parse_query(URI(url).query)

    assert_equal "cloud.ouraring.com", URI(url).host
    assert_equal "state-value", query["state"]
    assert_equal OuraApi::SCOPES.sort, query["scope"].split.sort
  end

  test "exchanges authorization code into canonical service credentials" do
    @adapter.stub :token_request, {
      "access_token" => "oura-access",
      "refresh_token" => "oura-refresh",
      "expires_in" => 86_400,
      "scope" => OuraApi::SCOPES.join(" ")
    } do
      @adapter.stub :fetch_identity, { "id" => "oura-123", "email" => "person@example.test" } do
        result = @adapter.exchange_code(
          code: "provider-code",
          attempt: @attempt,
          redirect_uri: "https://example.test/service_authorizations/callback"
        )

        assert_equal "oura-123", result[:external_subject_id]
        assert_equal "person@example.test", result[:external_identity]
        assert_equal :connected_user, result[:match_existing_by]
        assert_equal "oura-refresh", result.dig(:credential_payload, "refresh_token")
      end
    end
  end

  test "rotating access tokens stays in the service connection" do
    connection = accounts(:personal_account).service_connections.create!(
      connected_by_user: users(:user_1),
      provider: "oura",
      external_subject_id: "oura-123",
      management_scope: "personal",
      credential_kind: "oauth2",
      credential_payload_hash: {
        "access_token" => "expired",
        "refresh_token" => "old-refresh",
        "expires_at" => 1.hour.ago.utc.iso8601
      },
      credential_metadata: { "credential_strategy" => "refresh_broker" }
    )

    @adapter.stub :token_request, {
      "access_token" => "fresh-access",
      "refresh_token" => "fresh-refresh",
      "expires_in" => 86_400
    } do
      assert_equal "fresh-access", @adapter.current_access_token(connection)
    end

    assert_equal "fresh-refresh", connection.reload.credential_payload_hash["refresh_token"]
  end

end
