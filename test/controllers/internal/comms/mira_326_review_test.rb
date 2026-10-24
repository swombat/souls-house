require "test_helper"
# Mira's five regressions from her review of #326 at 985cb3b0, kept as she
# wrote them except that the concurrent restart is now begin_login_attempt!.
require "support/telegram_comms_helpers"

class Mira326ReviewTest < ActionDispatch::IntegrationTest
  include TelegramCommsHelpers

  setup do
    @connection = telegram_connection(account: accounts(:personal_account), user: users(:user_1))
  end

  test "connected without generation cannot finish a cancelled login" do
    @connection.update!(status: "pairing", login_generation: 4,
                        connector_state: { "login" => { "error" => "cancelled" } })
    post_telegram_event @connection, { type: "status.changed", status: "connected",
                                      identity: { user_id: "old-account" } }
    assert_response :conflict
    assert_equal "pairing", @connection.reload.status
  end

  test "an obsolete login event can be skipped durably so the outbox can progress" do
    @connection.update!(status: "pairing", login_generation: 4)
    post_telegram_event @connection, { type: "login.qr", seq: 1, generation: 3,
                                      code: "tg://login?token=fake",
                                      issued_at: Time.current.utc.iso8601,
                                      expires_at: 30.seconds.from_now.utc.iso8601 }
    assert_nil @connection.reload.pairing_qr
    post_telegram_event @connection, { type: "status.changed", status: "connected",
                                      seq: 2, generation: 4, identity: { user_id: "new-account" } }
    assert_response :ok
    assert_equal 2, @connection.reload.comms_event_seq
  end

  test "an edit preceding backfill must survive an older message delivery" do
    @connection.comms_chats.create!(provider_chat_id: "user:1")
    post_telegram_event @connection, {
      type: "message.edit", seq: 1,
      messages: [{ chat: "user:1", provider_message_id: "7", body: "current",
                   edited_at: "2026-10-12T10:05:00Z" }]
    }
    assert_response :ok
    post_telegram_event @connection, {
      type: "message.upsert", seq: 2,
      messages: [{ chat: "user:1", provider_message_id: "7", body: "obsolete",
                   sent_at: "2026-10-12T10:00:00Z" }]
    }
    assert_response :ok
    assert_equal "current", @connection.comms_messages.sole.body
  end

  test "cancel targets the generation actually invalidated under the lock" do
    @connection.update!(status: "pairing", login_generation: 4)
    stale = ServiceConnection.find(@connection.id)
    @connection.begin_login_attempt!
    commands = []
    CommsConnector.stub(:telegram_command, ->(conn, operation, **fields) {
      commands << [operation, fields]
      {}
    }) do
      stale.definition.adapter.cancel_login(stale)
    end
    assert_equal 6, stale.reload.login_generation
    assert_equal 5, commands.sole.last[:generation]
  end

  test "a delayed cancel response does not overwrite a restarted password prompt" do
    @connection.update!(status: "pairing", login_generation: 4)
    sign_in users(:user_1)
    CommsConnector.stub(:telegram_command, ->(conn, operation, **fields) {
      newer = ServiceConnection.find(conn.id)
      newer.begin_login_attempt!
      newer.update!(connector_state: { "login" => { "step" => "password" } })
      {}
    }) do
      post cancel_account_service_connection_login_path(@connection.account, @connection.public_id), as: :json
    end
    assert_response :ok
    assert_equal 6, @connection.reload.login_generation
    assert_equal "password", @connection.login_state["step"]
  end
end
