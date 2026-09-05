require "test_helper"

class ConnectionTest < ActionCable::Connection::TestCase

  tests ApplicationCable::Connection

  test "websocket authentication reads this instance's signed cookie" do
    session = users(:user_1).sessions.create!
    cookies.signed[LocalInstance.current.cookie(:session_id)] = session.id
    connect
    assert_equal session.user, connection.current_user
  end

  test "a valid legacy cookie cannot log into an isolated test instance" do
    session = users(:user_1).sessions.create!
    cookies.signed[:session_id] = session.id
    assert_reject_connection { connect }
  end

end
