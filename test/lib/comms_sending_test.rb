require "test_helper"
require "support/comms_send_helpers"

# CommsSending's dispatch-time checks and the attribution of echoed messages
# (spec §5), driven step by step through the claim/dispatch seam.
class CommsSendingTest < ActiveSupport::TestCase

  include CommsSendHelpers

  setup do
    setup_comms_send
    grant_send!
  end

  test "a grant withdrawn between request and dispatch stops the send" do
    send, created = claim
    assert created
    @access.change_send_grant!(false, actor: @account_admin)

    calls = with_fake_connector { CommsSending.deliver!(send) }

    assert_empty calls
    assert_equal [ "failed", "refused_at_dispatch_send_not_granted" ], [ send.reload.status, send.error_code ]
  end

  test "access disabled, or the connection disconnected, between request and dispatch stops the send" do
    send, = claim("a")
    @agent.set_service_access!(@connection, enabled: false, actor: @owner)
    calls = with_fake_connector { CommsSending.deliver!(send) }
    assert_empty calls
    assert_equal "failed", send.reload.status

    @agent.set_service_access!(@connection, enabled: true, actor: @owner)
    grant_send!(@access.reload)
    send, = claim("b")
    @connection.update!(status: "reauthorizing")
    calls = with_fake_connector { CommsSending.deliver!(send) }
    assert_empty calls
    assert_equal [ "failed", "refused_at_dispatch_not_connected" ], [ send.reload.status, send.error_code ]
  end

  test "a send already dispatched is never dispatched again" do
    send, = claim
    with_fake_connector { CommsSending.deliver!(send) }
    calls = with_fake_connector { CommsSending.deliver!(send.reload) }
    assert_empty calls
    assert_equal "sent", send.reload.status
  end

  test "a crash between claim and dispatch leaves pending, and a retry dispatches it exactly once" do
    send, = claim("early")
    # ...the process dies here: claimed, never dispatched, connector never called.
    assert_equal "pending", send.reload.status

    calls = with_fake_connector do
      result = CommsSending.request!(connection: @connection, agent: @agent, chat: @chat, text: "hello", client_request_id: "early")
      assert_not result.created
      assert_equal "sent", result.send.status
    end
    assert_equal 1, calls.size

    calls = with_fake_connector do
      CommsSending.request!(connection: @connection, agent: @agent, chat: @chat, text: "hello", client_request_id: "early")
    end
    assert_empty calls
  end

  test "a crash after dispatch leaves the send unknown, and a retry does not resend" do
    send, = claim("crash")
    assert CommsSending.dispatch!(send)
    # ...the process dies here, before the connector answers.
    assert_equal "unknown", send.reload.status

    calls = with_fake_connector do
      result = CommsSending.request!(connection: @connection, agent: @agent, chat: @chat, text: "hello", client_request_id: "crash")
      assert_not result.created
      assert_equal "unknown", result.send.status
    end
    assert_empty calls
  end

  test "echo before ack: the echo links to the send as soon as it arrives" do
    send, = claim
    linked_during_call = nil
    answer = lambda do |dispatched|
      # The connector's echo arrives while Rails is still waiting for the ack.
      receive_message(provider_message_id: dispatched.provider_message_id, from_me: true, body: "hello")
      linked_during_call = CommsMessage.find_by!(provider_message_id: dispatched.provider_message_id).comms_send_id
      sent_outcome(dispatched)
    end
    with_fake_connector(answer) { CommsSending.deliver!(send) }

    assert_equal send.id, linked_during_call
    message = CommsMessage.find_by!(provider_message_id: send.reload.provider_message_id)
    assert_equal send.id, message.comms_send_id
    assert_equal "hello", message.body
  end

  test "echo before ack when the connector used a different message id: the ack links it" do
    send, = claim
    answer = lambda do |dispatched|
      receive_message(provider_message_id: "3EB0OTHERID", from_me: true, body: "hello")
      sent_outcome(dispatched, provider_message_id: "3EB0OTHERID")
    end
    with_fake_connector(answer) { CommsSending.deliver!(send) }

    assert_equal "3EB0OTHERID", send.reload.provider_message_id
    assert_equal send.id, CommsMessage.find_by!(provider_message_id: "3EB0OTHERID").comms_send_id
  end

  test "ack before echo: the later echo links to the send, and the body is never rewritten" do
    send, = claim
    with_fake_connector { CommsSending.deliver!(send) }
    assert_equal "sent", send.reload.status

    receive_message(provider_message_id: send.provider_message_id, from_me: true, body: "hello")
    message = CommsMessage.find_by!(provider_message_id: send.provider_message_id)
    assert_equal send.id, message.comms_send_id

    # A redelivery with another body changes nothing: the first insert wins.
    receive_message(provider_message_id: send.provider_message_id, from_me: true, body: "rewritten")
    assert_equal "hello", message.reload.body
    assert_equal send.id, message.comms_send_id
  end

  test "a message that is not from me is never attributed to a send" do
    send, = claim
    with_fake_connector { CommsSending.deliver!(send) }
    receive_message(provider_message_id: send.reload.provider_message_id, from_me: false, body: "hello")
    assert_nil CommsMessage.find_by!(provider_message_id: send.provider_message_id).comms_send_id
  end

  test "residents reading the chat see which resident sent a message" do
    send, = claim
    with_fake_connector { CommsSending.deliver!(send) }
    receive_message(provider_message_id: send.reload.provider_message_id, from_me: true, body: "hello")

    json = CommsMessage.find_by!(provider_message_id: send.provider_message_id).as_comms_json
    assert json[:from_me]
    assert_equal({ resident_id: @agent.to_param, resident_name: @agent.name, send_id: send.public_id }, json[:sent_by])
  end

  private

  def claim(id = "seam")
    CommsSending.claim!(connection: @connection, agent: @agent, chat: @chat, text: "hello", client_request_id: id)
  end

  def receive_message(provider_message_id:, from_me:, body:)
    CommsEvents.receive!(@connection, {
      "type" => "message.upsert",
      "messages" => [ { "provider_message_id" => provider_message_id, "chat" => @chat.provider_chat_id, "from_me" => from_me,
                        "sent_at" => "2026-10-09T12:00:00Z", "body" => body } ]
    }, nonce: SecureRandom.hex(16))
  end

end
