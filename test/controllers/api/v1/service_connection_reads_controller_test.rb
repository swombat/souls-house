require "test_helper"
require "webmock/minitest"

module Api
  module V1
    class ServiceConnectionReadsControllerTest < ActionDispatch::IntegrationTest

      setup do
        @agent = agents(:research_assistant)
        @user = users(:user_1)
        @api_key = ApiKey.generate_for(@user, name: "Monzo reads", agent: @agent)
        @connection = @agent.account.service_connections.create!(
          connected_by_user: @user,
          provider: "monzo",
          external_subject_id: "user_000monzo",
          management_scope: "personal",
          credential_kind: "oauth2",
          credential_payload_hash: {
            "access_token" => "house-held-access",
            "refresh_token" => "house-held-refresh",
            "expires_at" => 2.hours.from_now.utc.iso8601
          },
          credential_metadata: { "credential_strategy" => "read_proxy" }
        )
        @access = @agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)
        @headers = { "Authorization" => "Bearer #{@api_key.raw_token}" }
      end

      test "forwards a readable GET and returns Monzo's answer, never the token" do
        stub_request(:get, "https://api.monzo.com/transactions?account_id=acc_1&limit=100")
          .with(headers: { "Authorization" => "Bearer house-held-access" })
          .to_return(status: 200, body: { transactions: [ { id: "tx_1", amount: -510 } ] }.to_json)

        get api_v1_service_connection_read_proxy_url(@connection.public_id, path: "transactions"),
          params: { account_id: "acc_1", limit: 100 }, headers: @headers

        assert_response :ok
        assert_equal "no-store", response.headers["Cache-Control"]
        assert_equal -510, JSON.parse(response.body).dig("transactions", 0, "amount")
        assert_no_match "house-held", response.body
      end

      test "refuses a path that writes, before anything reaches Monzo" do
        get api_v1_service_connection_read_proxy_url(@connection.public_id, path: "pots/pot_1/withdraw"), headers: @headers

        assert_response :forbidden
        assert_not_requested :any, /api\.monzo\.com/
      end

      test "is GET only" do
        assert_raises(ActionController::RoutingError) do
          Rails.application.routes.recognize_path(
            "/api/v1/service_connections/#{@connection.public_id}/read/pots", method: :put
          )
        end
      end

      test "refuses a resident whose access is disabled" do
        @access.update!(enabled: false)

        get api_v1_service_connection_read_proxy_url(@connection.public_id, path: "accounts"), headers: @headers

        assert_response :not_found
      end

      test "refuses while the connection needs reconnecting" do
        @connection.update!(status: "reauthorizing")

        get api_v1_service_connection_read_proxy_url(@connection.public_id, path: "accounts"), headers: @headers

        assert_response :conflict
      end

      test "refuses a connection that hands residents its own credential" do
        @connection.update!(credential_metadata: { "credential_strategy" => "refresh_broker" })

        get api_v1_service_connection_read_proxy_url(@connection.public_id, path: "accounts"), headers: @headers

        assert_response :unprocessable_entity
      end

      test "the resident's manifest names the proxy and carries no token" do
        credentials = @connection.runtime_credentials(agent: @agent)

        assert_equal [ "api_endpoint" ], credentials.keys
        assert_match %r{/api/v1/service_connections/#{@connection.public_id}/read\z}, credentials["api_endpoint"]
        assert_no_match "house-held", credentials.to_json
      end

    end
  end
end
