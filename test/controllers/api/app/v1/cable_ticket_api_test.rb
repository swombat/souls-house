require "test_helper"
require "support/app_oauth_test_helper"

# #94 B, step 6: a device trades its bearer token for a one-use cable ticket.
class Api::App::V1::CableTicketApiTest < ActionDispatch::IntegrationTest

  include AppOauthTestHelper

  setup do
    @user = users(:existing_user)
    @client = create_app_client
    @tokens = sign_in_device
  end

  test "issues a 60-second ticket bound to the device, storing only its digest" do
    freeze_time do
      post "/api/app/v1/cable_ticket", headers: bearer(@tokens)

      assert_response :created
      body = response.parsed_body
      assert_equal "#{AppCableTicket::PROTOCOL_PREFIX}#{body['ticket']}", body["protocol"]
      assert_equal 60.seconds.from_now.iso8601(3), body["expires_at"]
      assert_match(/\A[A-Za-z0-9_-]{40,}\z/, body["ticket"], "a WebSocket subprotocol must be an RFC 6455 token")

      ticket = AppCableTicket.sole
      assert_equal row_for(@tokens).app_session_id, ticket.app_session_id
      assert_equal Digest::SHA256.hexdigest(body["ticket"]), ticket.token_digest
      assert_not AppCableTicket.where(token_digest: body["ticket"]).exists?
    end
  end

  test "needs a usable bearer token" do
    post "/api/app/v1/cable_ticket"
    assert_response :unauthorized

    row_for(@tokens).app_session.revoke!(:user_revoked)
    post "/api/app/v1/cable_ticket", headers: bearer(@tokens)
    assert_response :unauthorized
    assert_equal 0, AppCableTicket.count
  end

  test "issuing clears the device's expired tickets and leaves live ones" do
    post "/api/app/v1/cable_ticket", headers: bearer(@tokens)
    travel 2.minutes
    @tokens = refresh(@tokens)
    post "/api/app/v1/cable_ticket", headers: bearer(@tokens)
    post "/api/app/v1/cable_ticket", headers: bearer(@tokens)

    assert_equal 2, AppCableTicket.count
    assert AppCableTicket.all.all? { |ticket| ticket.expires_at.future? }
  end

  test "ticket values are filtered from Rails and Honeybadger request data" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("ticket" => "t", "HTTP_SEC_WEBSOCKET_PROTOCOL" => "actioncable-v1-json, souls-house.ticket.t")
    assert_equal [ "[FILTERED]" ], filtered.values.uniq

    assert_includes Honeybadger.config.params_filters, "HTTP_SEC_WEBSOCKET_PROTOCOL"
    assert_includes Honeybadger.config.params_filters, "HTTP_AUTHORIZATION"
  end

end
