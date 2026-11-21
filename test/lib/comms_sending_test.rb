require "test_helper"
require "support/comms_send_helpers"

# CommsSending's dispatch-time checks, pacing and the attribution of echoed
# messages (WhatsApp spec §5), driven step by step through the
# claim/dispatch seam, with echoes through the current CommsEvents (edits,
# tombstones and placeholders included).
class CommsSendingTest < ActiveSupport::TestCase

  include CommsSendHelpers

  setup do
    setup_comms_send
    grant_send!
  end

  teardown { teardown_comms_send }

  test "the claim picks a WhatsApp message id in whatsmeow's format and records the session" do
    send, created = claim
    assert created
    assert_match Services::WhatsappAdapter::SEND_MESSAGE_ID_FORMAT, send.provider_message_id
    assert_equal 20, send.provider_message_id.length
    assert_equal @connection.pairing_attempt, send.connection_generation
    assert_equal "pending", send.status
    ids = 50.times.map { Services::Definition.fetch("whatsapp").adapter.new_send_message_id }
    assert ids.all? { |id| id.match?(/\A3EB0[0-9A-F]{16}\z/) }, "the shape the connector accepts, exactly"
    assert_equal 50, ids.uniq.size
  end

  test "a grant withdrawn between claim and dispatch stops the send" do
    send, = claim
    @access.change_send_grant!(false, actor: @account_admin)

    calls = with_fake_connector { CommsSending.deliver!(send) }

    assert_empty calls
    assert_equal [ "failed", "refused_at_dispatch_send_not_granted", nil ], [ send.reload.status, send.error_code, send.dispatched_at ]
  end

  test "access disabled, the connection disconnected, or sending switched off between claim and dispatch stops the send" do
    send, = claim("a")
    @agent.set_service_access!(@connection, enabled: false, actor: @owner)
    assert_empty with_fake_connector { CommsSending.deliver!(send) }
    assert_equal [ "failed", "refused_at_dispatch_send_not_granted" ], [ send.reload.status, send.error_code ]

    @agent.set_service_access!(@connection, enabled: true, actor: @owner)
    grant_send!(@access.reload)
    send, = claim("b")
    without_sending do
      assert_empty with_fake_connector { CommsSending.deliver!(send) }
    end
    assert_equal [ "failed", "refused_at_dispatch_not_available" ], [ send.reload.status, send.error_code ]

    send, = claim("c")
    @connection.update!(status: "reauthorizing")
    assert_empty with_fake_connector { CommsSending.deliver!(send) }
    assert_equal [ "failed", "refused_at_dispatch_not_connected" ], [ send.reload.status, send.error_code ]
  end

  test "a send claimed under an earlier session is refused at dispatch" do
    send, = claim
    # The generation moves on without leaving "connected" (which would also
    # withdraw the grant); dispatch checks it independently.
    send.update_columns(connection_generation: send.connection_generation - 1)
    assert_empty with_fake_connector { CommsSending.deliver!(send) }
    assert_equal [ "failed", "refused_at_dispatch_stale_generation" ], [ send.reload.status, send.error_code ]
  end

  test "the send is unknown with dispatched_at while the connector is called" do
    send, = claim
    seen = nil
    answer = lambda do |dispatched|
      seen = CommsSend.find(dispatched.id).attributes.slice("status", "dispatched_at")
      sent_outcome(dispatched)
    end
    with_fake_connector(answer) { CommsSending.deliver!(send) }
    assert_equal "unknown", seen["status"]
    assert seen["dispatched_at"]
    assert_equal "sent", send.reload.status
  end

  test "only the connector's explicit answer decides: unknown stays unknown, failed carries the reason" do
    send, = claim("u")
    with_fake_connector(->(_) { CommsConnector::SendOutcome.unknown("connector_timeout") }) { CommsSending.deliver!(send) }
    assert_equal [ "unknown", "connector_timeout" ], [ send.reload.status, send.error_code ]

    send, = claim("f")
    with_fake_connector(->(_) { CommsConnector::SendOutcome.failed("refused", "not_on_whatsapp") }) { CommsSending.deliver!(send) }
    assert_equal [ "failed", "refused", "not_on_whatsapp" ], [ send.reload.status, send.error_code, send.error_reason ]
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
      result = request("early")
      assert_not result.created
      assert_equal "sent", result.send.status
    end
    assert_equal 1, calls.size

    assert_empty with_fake_connector { request("early") }
  end

  test "a crash after dispatch leaves the send unknown, and nothing resends it" do
    send, = claim("crash")
    assert CommsSending.dispatch!(send)
    # ...the process dies here, before the connector answers.
    assert_equal "unknown", send.reload.status

    calls = with_fake_connector do
      result = request("crash")
      assert_not result.created
      assert_equal "unknown", result.send.status
      CommsSending.deliver!(send.reload)
    end
    assert_empty calls
    assert_equal "unknown", send.reload.status
  end

  test "the same client_request_id with another chat or text is refused, and nothing is sent" do
    with_fake_connector { request("dup") }
    other_chat = @connection.comms_chats.create!(provider_chat_id: "447700900999@s.whatsapp.net", kind: "direct")
    calls = with_fake_connector do
      assert_equal :client_request_id_reused, assert_raises(CommsSending::Refused) { request("dup", text: "different") }.code
      error = assert_raises(CommsSending::Refused) do
        CommsSending.request!(connection: @connection, agent: @agent, chat: other_chat, text: "hello", client_request_id: "dup")
      end
      assert_equal :conflict, error.status
    end
    assert_empty calls
    assert_equal 1, @connection.comms_sends.count
  end

  test "a new claim over the cap is refused with 429 and creates nothing" do
    fill_dispatched(CommsSending::PER_MINUTE, at: 10.seconds.ago)
    calls = with_fake_connector do
      error = assert_raises(CommsSending::Refused) { request("over") }
      assert_equal [ :rate_limited, :too_many_requests ], [ error.code, error.status ]
    end
    assert_empty calls
    assert_nil @connection.comms_sends.find_by(client_request_id: "over")
  end

  test "pending claims inside the window reserve slots at claim" do
    (CommsSending::PER_MINUTE).times { |n| claim("reserved-#{n}") }
    assert_equal :rate_limited, assert_raises(CommsSending::Refused) { claim("one-more") }.code
  end

  test "an old pending backlog retried against a full minute is refused at dispatch with no connector call" do
    backlog = old_pending_backlog(3)
    fill_dispatched(CommsSending::PER_MINUTE, at: 10.seconds.ago)

    calls = with_fake_connector do
      backlog.each { |send| assert_not request(send.client_request_id, text: send.text).created }
    end

    assert_empty calls
    backlog.each do |send|
      assert_equal [ "failed", "refused_at_dispatch_rate_limited", nil ], [ send.reload.status, send.error_code, send.dispatched_at ]
    end
  end

  test "an old pending backlog with two free slots makes exactly two connector calls" do
    backlog = old_pending_backlog(CommsSending::PER_MINUTE + 3)
    room = 2
    fill_dispatched(CommsSending::PER_MINUTE - room, at: 10.seconds.ago)

    calls = with_fake_connector do
      backlog.each { |send| request(send.client_request_id, text: send.text) }
    end

    assert_equal room, calls.size
    assert_equal room, @connection.comms_sends.where(id: backlog.map(&:id), status: "sent").count
    assert_equal backlog.size - room, @connection.comms_sends.where(id: backlog.map(&:id), error_code: "refused_at_dispatch_rate_limited").count
    assert_equal CommsSending::PER_MINUTE, @connection.comms_sends.where(dispatched_at: 1.minute.ago..).count
  end

  test "the daily cap is counted by dispatch time too" do
    backlog = old_pending_backlog(1)
    fill_dispatched(CommsSending::PER_DAY, at: 2.hours.ago)
    assert_empty with_fake_connector { CommsSending.deliver!(backlog.first) }
    assert_equal "refused_at_dispatch_rate_limited", backlog.first.reload.error_code

    # Sends requested long ago but dispatched within the day still count at
    # claim time too.
    CommsSend.where(service_connection_id: @connection.id, status: "sent").update_all(requested_at: 3.days.ago)
    assert_equal :rate_limited, assert_raises(CommsSending::Refused) { request("new-today") }.code
  end

  test "a send is charged once: a retry of a dispatched send neither calls the connector nor counts again" do
    fill_dispatched(CommsSending::PER_MINUTE - 1, at: 10.seconds.ago)
    send, = claim("charged-once")
    assert_equal 1, with_fake_connector { CommsSending.deliver!(send) }.size
    dispatched_at = send.reload.dispatched_at
    assert dispatched_at

    calls = with_fake_connector { 3.times { request("charged-once") } }
    assert_empty calls
    assert_equal dispatched_at, send.reload.dispatched_at
    assert_equal CommsSending::PER_MINUTE, @connection.comms_sends.where(dispatched_at: 1.minute.ago..).count
  end

  test "refused and never-dispatched sends do not use up the limit" do
    CommsSend.insert_all!((1..CommsSending::PER_MINUTE).map do |n|
      row("refused-#{n}", status: "failed", requested_at: 10.seconds.ago).merge(error_code: "refused_at_dispatch_send_not_granted")
    end)
    calls = with_fake_connector { assert_equal "sent", request("after-refusals").send.status }
    assert_equal 1, calls.size
  end

  test "echo before ack: the echo links to the send as soon as it arrives" do
    send, = claim
    linked_during_call = nil
    answer = lambda do |dispatched|
      # The connector's echo arrives while Rails is still waiting for the ack.
      receive_message(dispatched.provider_message_id, body: "hello")
      linked_during_call = @chat.comms_messages.find_by!(provider_message_id: dispatched.provider_message_id).comms_send_id
      sent_outcome(dispatched)
    end
    with_fake_connector(answer) { CommsSending.deliver!(send) }

    assert_equal send.id, linked_during_call
    message = @chat.comms_messages.find_by!(provider_message_id: send.reload.provider_message_id)
    assert_equal [ send.id, "hello" ], [ message.comms_send_id, message.body ]
  end

  test "echo before ack under another message id: the ack links it" do
    send, = claim
    other_id = "3EB0#{"B" * 16}"
    answer = lambda do |dispatched|
      receive_message(other_id, body: "hello")
      sent_outcome(dispatched, provider_message_id: other_id)
    end
    with_fake_connector(answer) { CommsSending.deliver!(send) }

    assert_equal other_id, send.reload.provider_message_id
    assert_equal send.id, @chat.comms_messages.find_by!(provider_message_id: other_id).comms_send_id
  end

  test "ack before echo: the later echo links to the send, and the body is never rewritten" do
    send, = claim
    with_fake_connector { CommsSending.deliver!(send) }
    assert_equal "sent", send.reload.status

    receive_message(send.provider_message_id, body: "hello")
    message = @chat.comms_messages.find_by!(provider_message_id: send.provider_message_id)
    assert_equal send.id, message.comms_send_id

    # A redelivery with another body changes nothing: the first insert wins.
    receive_message(send.provider_message_id, body: "rewritten")
    assert_equal [ "hello", send.id ], [ message.reload.body, message.comms_send_id ]
  end

  test "the link survives an edit and a deletion of the echoed message" do
    send, = claim
    with_fake_connector { CommsSending.deliver!(send) }
    receive_message(send.reload.provider_message_id, body: "hello")

    receive_event("message.edit", "messages" => [ { "provider_message_id" => send.provider_message_id, "chat" => @chat.provider_chat_id,
                                                    "body" => "hello (edited)", "edited_at" => "2026-10-24T12:05:00Z" } ])
    message = @chat.comms_messages.find_by!(provider_message_id: send.provider_message_id)
    assert_equal [ "hello (edited)", send.id ], [ message.body, message.comms_send_id ]
    assert_equal "hello", send.reload.text, "the send keeps what the resident asked to send"

    receive_event("message.delete", "deletions" => [ { "chat" => @chat.provider_chat_id, "provider_message_ids" => [ send.provider_message_id ],
                                                       "deleted_at" => "2026-10-24T12:06:00Z" } ])
    message.reload
    assert message.deleted?
    assert_nil message.body
    assert_equal send.id, message.comms_send_id
  end

  test "a placeholder that came first (an edit before the ack) links, and keeps the link once the ack fills it" do
    send, = claim
    placeholder = nil
    answer = lambda do |dispatched|
      receive_event("message.edit", "messages" => [ { "provider_message_id" => dispatched.provider_message_id, "chat" => @chat.provider_chat_id,
                                                      "body" => "hello!", "edited_at" => "2026-10-24T12:05:00Z" } ])
      placeholder = @chat.comms_messages.find_by!(provider_message_id: dispatched.provider_message_id).attributes.slice("placeholder", "comms_send_id")
      sent_outcome(dispatched)
    end
    with_fake_connector(answer) { CommsSending.deliver!(send) }
    assert_equal({ "placeholder" => true, "comms_send_id" => send.id }, placeholder)

    message = @chat.comms_messages.sole
    assert_not message.placeholder?, "the ack filled it"
    assert_equal [ "hello!", send.id ], [ message.body, message.comms_send_id ], "the newer edited content is kept"

    receive_message(send.reload.provider_message_id, body: "hello")
    assert_equal [ "hello!", send.id ], [ message.reload.body, message.comms_send_id ]
    assert_equal 1, @chat.comms_messages.count
  end

  test "ack only, no echo ever: the house stores exactly one linked message from the owner" do
    @connection.update!(external_subject_id: "447700900001", external_identity: "Daniel")
    assert_not @access.reload.can_send?, "a new identity withdrew the grant"
    grant_send!(@access)
    send, = claim
    with_fake_connector { CommsSending.deliver!(send) }

    message = @chat.comms_messages.sole
    assert_equal [ send.reload.provider_message_id, "hello", send.id, "447700900001@s.whatsapp.net", "Daniel" ],
                 [ message.provider_message_id, message.body, message.comms_send_id, message.sender_id, message.sender_name ]
    assert_equal Time.iso8601("2026-10-24T12:00:00Z"), message.sent_at
    assert_equal message.sent_at, @chat.reload.last_activity_at
  end

  test "a late ack after the connection's account changed keeps the sender fixed at dispatch" do
    @connection.update!(external_subject_id: "447700900001", external_identity: "Daniel")
    grant_send!(@access.reload)
    send, = claim
    # The connection names another account while the send is with the
    # connector (a re-pair onto another number); the acknowledgement for the
    # message that went out from the first account arrives afterwards.
    answer = lambda do |dispatched|
      @connection.update!(external_subject_id: "447700900002", external_identity: "Someone else")
      sent_outcome(dispatched)
    end
    with_fake_connector(answer) { CommsSending.deliver!(send) }

    send.reload
    assert_equal "sent", send.status
    message = @chat.comms_messages.sole
    assert_equal [ send.id, "447700900001@s.whatsapp.net", "Daniel" ],
                 [ message.comms_send_id, message.sender_id, message.sender_name ]

    # A later echo of the same message neither duplicates it nor moves it
    # to the new account.
    receive_message(send.provider_message_id, body: "hello")
    message = @chat.comms_messages.sole
    assert_equal [ send.id, "447700900001@s.whatsapp.net" ], [ message.comms_send_id, message.sender_id ]
  end

  test "echo before ack, and ack before echo, each leave exactly one linked message" do
    send, = claim("first")
    answer = lambda do |dispatched|
      receive_message(dispatched.provider_message_id, body: "hello")
      sent_outcome(dispatched)
    end
    with_fake_connector(answer) { CommsSending.deliver!(send) }
    assert_equal [ [ send.reload.provider_message_id, send.id ] ], @chat.comms_messages.pluck(:provider_message_id, :comms_send_id)

    later, = claim("second")
    with_fake_connector { CommsSending.deliver!(later) }
    receive_message(later.reload.provider_message_id, body: "hello")
    assert_equal 2, @chat.comms_messages.count
    assert_equal later.id, @chat.comms_messages.find_by!(provider_message_id: later.provider_message_id).comms_send_id
  end

  test "a failed or unknown send stores no message" do
    send, = claim("u2")
    with_fake_connector(->(_) { CommsConnector::SendOutcome.unknown("connector_timeout") }) { CommsSending.deliver!(send) }
    send, = claim("f2")
    with_fake_connector(->(_) { CommsConnector::SendOutcome.failed("not_on_whatsapp") }) { CommsSending.deliver!(send) }
    assert_equal 0, @chat.comms_messages.count
  end

  test "a message with the same id in another chat is never attributed" do
    send, = claim
    with_fake_connector { CommsSending.deliver!(send) }
    other = @connection.comms_chats.create!(provider_chat_id: "447700900999@s.whatsapp.net", kind: "direct")
    receive_message(send.reload.provider_message_id, body: "hello", chat: other)
    assert_nil other.comms_messages.find_by!(provider_message_id: send.provider_message_id).comms_send_id
  end

  test "residents reading the chat see which resident sent a message" do
    send, = claim
    with_fake_connector { CommsSending.deliver!(send) }
    receive_message(send.reload.provider_message_id, body: "hello")

    json = @chat.comms_messages.find_by!(provider_message_id: send.provider_message_id).as_comms_json
    assert_equal({ resident_id: @agent.to_param, resident_name: @agent.name, send_id: send.public_id }, json[:sent_by])
    receive_message("3EB0#{"C" * 16}", body: "from Alice")
    assert_nil @chat.comms_messages.find_by!(provider_message_id: "3EB0#{"C" * 16}").as_comms_json[:sent_by]
  end

  private

  def claim(id = "seam")
    CommsSending.claim!(connection: @connection, agent: @agent, chat: @chat, text: "hello", client_request_id: id)
  end

  def request(id, text: "hello")
    CommsSending.request!(connection: @connection, agent: @agent, chat: @chat, text: text, client_request_id: id)
  end

  def row(id, status:, requested_at:, dispatched_at: nil)
    now = Time.current
    { service_connection_id: @connection.id, agent_id: @agent.id, comms_chat_id: @chat.id, text: "text #{id}",
      client_request_id: id, status: status, requested_at: requested_at, dispatched_at: dispatched_at,
      provider_message_id: "3EB0#{SecureRandom.hex(8).upcase}", connection_generation: @connection.pairing_attempt,
      created_at: now, updated_at: now }
  end

  # Pending claims made long ago (outside both windows) whose requests died
  # before dispatch.
  def old_pending_backlog(count)
    (1..count).map do |n|
      @connection.comms_sends.create!(row("backlog-#{n}", status: "pending", requested_at: 3.days.ago)
                                        .except(:service_connection_id, :created_at, :updated_at))
    end
  end

  def fill_dispatched(count, at:)
    CommsSend.insert_all!((1..count).map { |n| row("earlier-#{at.to_i}-#{n}", status: "sent", requested_at: at, dispatched_at: at) })
  end

  def receive_message(provider_message_id, body:, chat: @chat)
    receive_event("message.upsert", "messages" => [ { "provider_message_id" => provider_message_id, "chat" => chat.provider_chat_id,
                                                      "sender_id" => "447700900001@s.whatsapp.net",
                                                      "sent_at" => "2026-10-24T12:00:00Z", "body" => body } ])
  end

  def receive_event(type, fields)
    CommsEvents.receive!(@connection.reload, { "type" => type, "attempt" => @connection.pairing_attempt }.merge(fields), nonce: SecureRandom.hex(16))
  end

end
