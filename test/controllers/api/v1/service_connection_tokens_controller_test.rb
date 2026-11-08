require "test_helper"
require "webmock/minitest"

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

      test "Google rejected refresh returns readable refusal on the first and subsequent calls" do
        @connection.update!(provider: "google_workspace", credential_payload_hash: {
          "access_token" => "expired", "refresh_token" => "private-refresh",
          "expires_at" => 1.minute.ago.iso8601
        })
        credentials = Object.new
        credentials.define_singleton_method(:dig) { |*| "fake-oauth-credential" }
        stub_request(:post, Services::GoogleWorkspaceAdapter::TOKEN_URL)
          .to_return(status: 400, body: { error: "invalid_grant", error_description: "private-provider-body" }.to_json)

        Rails.application.stub(:credentials, credentials) do
          2.times do
            get api_v1_service_connection_access_token_url(@connection.public_id),
              headers: { "Authorization" => "Bearer #{@api_key.raw_token}" }

            assert_response :conflict
            json = response.parsed_body
            assert_equal "provider_reauth_required", json["error"]
            assert_match(/reconnect Google Workspace in Integrations/, json["message"])
            assert_equal @connection.public_id, json["connection_id"]
            assert_nil json["last_good_refresh"]
            assert_not_includes response.body, "private"
          end
        end
        assert_requested :post, Services::GoogleWorkspaceAdapter::TOKEN_URL, times: 1
        assert_equal "reauthorizing", @connection.reload.status
        assert @access.reload.enabled?

        @access.update!(enabled: false)
        get api_v1_service_connection_access_token_url(@connection.public_id),
          headers: { "Authorization" => "Bearer #{@api_key.raw_token}" }
        assert_response :not_found
      end

      test "Google reauthorization reports only a recorded successful refresh" do
        last_good = 2.days.ago.change(usec: 0)
        @connection.update!(provider: "google_workspace", status: "reauthorizing", last_refreshed_at: last_good)
        get api_v1_service_connection_access_token_url(@connection.public_id),
          headers: { "Authorization" => "Bearer #{@api_key.raw_token}" }

        assert_response :conflict
        assert_equal last_good.utc.iso8601, response.parsed_body["last_good_refresh"]
      end

      test "ordinary Google provider errors remain bad gateway without marking reauthorization" do
        @connection.update!(provider: "google_workspace")
        adapter = Services::Definition.fetch("google_workspace").adapter
        adapter.stub(:current_access_token, ->(*) { raise Services::GoogleWorkspaceAdapter::Error, "Google unavailable" }) do
          Services::Definition.fetch("google_workspace").stub(:adapter, adapter) do
            get api_v1_service_connection_access_token_url(@connection.public_id),
              headers: { "Authorization" => "Bearer #{@api_key.raw_token}" }
          end
        end
        assert_response :bad_gateway
        assert_equal "Google unavailable", response.parsed_body["error"]
        assert_equal "connected", @connection.reload.status
      end

    end
  end
end
