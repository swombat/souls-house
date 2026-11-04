require "test_helper"

# The token broker and a guest's grant (JWblqj): pending is denied, approved
# serves the token, and ending it denies again.
module Api
  module V1
    class GuestGrantBrokerTest < ActionDispatch::IntegrationTest

      setup do
        @daniel = users(:user_1)
        @anna = users(:existing_user)
        @sharing = accounts(:team_account)
        @lume = agents(:research_assistant)
        @sharing.guest_memberships.create!(agent: @lume, added_by: @daniel)
        @api_key = ApiKey.generate_for(@daniel, name: "Lume broker", agent: @lume)
        @connection = @sharing.service_connections.create!(
          connected_by_user: @anna,
          provider: "oura",
          external_subject_id: "oura-anna",
          management_scope: "personal",
          credential_kind: "oauth2",
          credential_payload_hash: {
            "access_token" => "anna-access",
            "refresh_token" => "anna-refresh",
            "expires_at" => 2.days.from_now.utc.iso8601
          },
          credential_metadata: { "credential_strategy" => "refresh_broker" }
        )
        @access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
      end

      test "a pending guest grant gets no token" do
        fetch_token
        assert_response :not_found
      end

      test "an approved guest grant gets the token, and a revoked one does not" do
        @access.approve_home!(actor: @daniel, generation: 1)

        fetch_token
        assert_response :ok
        assert_equal "anna-access", JSON.parse(response.body)["access_token"]

        @access.revoke_home!(actor: @daniel)
        fetch_token
        assert_response :not_found
      end

      test "an approved grant whose seat ended gets no token" do
        @access.approve_home!(actor: @daniel, generation: 1)
        @sharing.guest_memberships.find_by!(agent: @lume).destroy!

        fetch_token
        assert_response :not_found
      end

      private

      def fetch_token
        get api_v1_service_connection_access_token_url(@connection.public_id),
          headers: { "Authorization" => "Bearer #{@api_key.raw_token}" }
      end

    end
  end
end
