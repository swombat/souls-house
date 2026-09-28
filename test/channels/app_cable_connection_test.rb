require "test_helper"

# #94 B, step 6: the native app opens the cable with a ticket offered in
# Sec-WebSocket-Protocol. The ticket alone authenticates it.
class AppCableConnectionTest < ActionCable::Connection::TestCase

  tests ApplicationCable::Connection

  setup do
    @user = users(:user_1)
    @client = Doorkeeper::Application.create!(name: "App", uid: "cable-test", redirect_uri: "https://souls.house/cb", scopes: "chat", confidential: false)
    @app_session = AppSession.create!(user: @user, oauth_application: @client, device_label: "Pixel")
    @value, = AppCableTicket.issue!(@app_session)
  end

  test "a ticket identifies the user and the device session" do
    connect headers: offering(@value)

    assert_equal @user, connection.current_user
    assert_equal @app_session, connection.current_app_session
    assert AppCableTicket.sole.consumed_at.present?
  end

  test "a ticket is single-use" do
    connect headers: offering(@value)
    assert_reject_connection { connect headers: offering(@value) }
  end

  test "a ticket expires after 60 seconds" do
    travel 61.seconds
    assert_reject_connection { connect headers: offering(@value) }
  end

  test "a ticket for a revoked session is refused" do
    @app_session.revoke!(:logout)
    assert_reject_connection { connect headers: offering(@value) }
  end

  test "an unknown ticket is refused and never falls back to the cookie" do
    session = @user.sessions.create!
    cookies.signed[LocalInstance.current.cookie(:session_id)] = session.id

    assert_reject_connection { connect headers: offering("forged") }
  end

  test "the web's cookie connection is unchanged and carries no device session" do
    session = @user.sessions.create!
    cookies.signed[LocalInstance.current.cookie(:session_id)] = session.id
    connect

    assert_equal @user, connection.current_user
    assert_nil connection.current_app_session
  end

  test "the origin check applies to cookie connections, not to ticket connections" do
    assert origin_allowed?(offering(@value)), "a native client sends no browser Origin"
    assert_not origin_allowed?({})
    assert_not origin_allowed?("Origin" => "https://evil.example")
    assert_nil AppCableTicket.find_by(token_digest: AppCableTicket.digest(@value)).consumed_at
  end

  private

  def origin_allowed?(headers)
    env = Rack::MockRequest.env_for("/cable", headers.transform_keys { |name| "HTTP_#{name.upcase.tr('-', '_')}" })
    ApplicationCable::Connection.new(ActionCable.server, env).send(:allow_request_origin?)
  end

  def offering(value)
    { "Sec-WebSocket-Protocol" => "actioncable-v1-json, #{AppCableTicket::PROTOCOL_PREFIX}#{value}" }
  end

end
