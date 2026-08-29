require "test_helper"

module Api
  module V1
    class ServiceConnectionTokensControllerTest < ActionDispatch::IntegrationTest

      setup do
        @agent = agents(:research_assistant)
        @user = users(:user_1)
        @api_key = ApiKey.generate_for(@user, name: "Oura broker", agent: @agent)
        @connection = @agent.account.service_connections.create!(
          connected_by_user: @user,
          provider: "oura",
          external_subject_id: "oura-123",
          management_scope: "personal",
          credential_kind: "oauth2",
          credential_payload_hash: {
            "access_token" => "current-access",
            "refresh_token" => "private-refresh",
            "expires_at" => 2.days.from_now.utc.iso8601
          },
          credential_metadata: { "credential_strategy" => "refresh_broker" }
        )
        @access = @agent.agent_service_accesses.create!(
          service_connection: @connection,
          enabled: true
        )
      end

      test "returns a current token only to an enabled resident" do
        get api_v1_service_connection_access_token_url(@connection.public_id),
          headers: { "Authorization" => "Bearer #{@api_key.raw_token}" }

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal "current-access", json["access_token"]
        assert_not json.key?("refresh_token")
      end

      test "does not expose a token after resident access is disabled" do
        @access.update!(enabled: false)

        get api_v1_service_connection_access_token_url(@connection.public_id),
          headers: { "Authorization" => "Bearer #{@api_key.raw_token}" }

        assert_response :not_found
      end

      test "does not expose a token while the connection is reauthorizing" do
        @connection.update!(status: "reauthorizing")

        get api_v1_service_connection_access_token_url(@connection.public_id),
          headers: { "Authorization" => "Bearer #{@api_key.raw_token}" }

        assert_response :conflict
        assert_equal "This service connection is not currently connected", JSON.parse(response.body)["error"]
      end

    end
  end
end
