require "test_helper"

class CompanionConnectionTest < ActionCable::Connection::TestCase

  tests ApplicationCable::Connection

  setup do
    agent = agents(:research_assistant)
    grant = CompanionEnrollmentGrant.create!(account: agent.account, minting_agent: agent,
      created_by_user: users(:user_1), name: "Fixture", device_request_id: "fixture",
      policy: { "residents" => [ { "id" => agent.obfuscated_id, "volumes" => [], "execute" => false } ] },
      expires_at: 1.hour.from_now)
    @device, = CompanionEnrollmentGrant.enroll!(grant.issue_token!(agent), "fixture")
    @ticket, = CompanionCableTicket.issue!(@device)
  end

  test "ticket identifies only device and is single use" do
    connect headers: offering(@ticket)
    assert_equal @device, connection.current_companion_device
    assert_nil connection.current_user
    assert_nil connection.current_app_session
    assert_reject_connection { connect headers: offering(@ticket) }
  end

  test "expired revoked or empty ticket has no cookie fallback" do
    session = users(:user_1).sessions.create!
    cookies.signed[LocalInstance.current.cookie(:session_id)] = session.id
    assert_reject_connection { connect headers: offering("") }
    travel 61.seconds
    assert_reject_connection { connect headers: offering(@ticket) }
    fresh, = CompanionCableTicket.issue!(@device)
    @device.revoke!
    assert_reject_connection { connect headers: offering(fresh) }
  end

  private

  def offering(value)
    { "Sec-WebSocket-Protocol" => "actioncable-v1-json, #{CompanionCableTicket::PROTOCOL_PREFIX}#{value}" }
  end

end
