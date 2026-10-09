require "test_helper"

# Real concurrency for CommsSending (spec §5): threads with their own
# database connections and committed rows, so the connection row lock and the
# claim's unique index are what is actually tested. Not transactional; the
# rows made here are removed in teardown.
class CommsSendingConcurrencyTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  THREADS = 4

  setup do
    @owner = users(:user_1)
    @agent = agents(:research_assistant)
    attributes = Services::Definition.fetch("whatsapp").adapter.connection_attributes(credentials: {}, user: @owner)
    @connection = @agent.account.service_connections.create!(
      connected_by_user: @owner, provider: "whatsapp", management_scope: "personal", status: "connected",
      label: attributes[:label], credential_kind: attributes[:credential_kind],
      credential_fingerprint: attributes[:credential_fingerprint], credential_metadata: attributes[:credential_metadata],
      credential_payload_hash: attributes[:credential_payload]
    )
    @access = @agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)
    @access.change_send_grant!(true, actor: @owner)
    @chat = @connection.comms_chats.create!(provider_chat_id: "447700900123@s.whatsapp.net", kind: "direct")
  end

  teardown do
    CommsMessage.where(service_connection_id: @connection.id).delete_all
    CommsSend.where(service_connection_id: @connection.id).delete_all
    CommsSendGrantEvent.where(service_connection_id: @connection.id).delete_all
    AgentServiceAccess.where(service_connection_id: @connection.id).delete_all
    CommsChat.where(service_connection_id: @connection.id).delete_all
    ServiceConnection.where(id: @connection.id).delete_all
  end

  test "simultaneous retries of one client_request_id make one record and one connector call" do
    calls, results = race { CommsSending.request!(connection: @connection, agent: @agent, chat: @chat, text: "hello", client_request_id: "same") }

    assert results.all? { |result| result.is_a?(CommsSending::Result) }, results.inspect
    assert_equal 1, CommsSend.where(service_connection_id: @connection.id).count
    assert_equal 1, calls.size
    assert_equal 1, results.count(&:created)
    assert_equal [ calls.first ], results.map { |result| result.send.id }.uniq
  end

  test "concurrent requests cannot pass the rate limit together" do
    room = 2
    now = Time.current
    CommsSend.insert_all!((1..(CommsSending::PER_MINUTE - room)).map do |n|
      { service_connection_id: @connection.id, agent_id: @agent.id, comms_chat_id: @chat.id, text: "earlier #{n}",
        client_request_id: "earlier-#{n}", status: "sent", requested_at: now - 10.seconds, created_at: now, updated_at: now }
    end)

    index = Concurrent::AtomicFixnum.new
    calls, results = race do
      CommsSending.request!(connection: @connection, agent: @agent, chat: @chat, text: "hello", client_request_id: "distinct-#{index.increment}")
    end

    created = results.select { |result| result.is_a?(CommsSending::Result) && result.created }
    refused = results.select { |result| result.is_a?(CommsSending::Refused) }
    assert_equal room, created.size, results.inspect
    assert_equal THREADS - room, refused.size
    assert refused.all? { |refusal| refusal.code == :rate_limited }
    assert_equal room, calls.size
    assert_equal CommsSending::PER_MINUTE, CommsSend.where(service_connection_id: @connection.id).count
  end

  private

  # Runs the block in THREADS threads released together. The fake connector
  # takes a moment, as a real one would. Returns the connector calls and each
  # thread's result (or the exception it raised).
  def race(&block)
    calls = Queue.new
    gate = Concurrent::CountDownLatch.new(1)
    fake = lambda do |send|
      calls << send.id
      sleep 0.2
      CommsConnector::SendOutcome.new(status: "sent", provider_message_id: send.provider_message_id, sent_at: Time.current, error_code: nil)
    end
    results = CommsConnector.stub(:send_text, fake) do
      threads = THREADS.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            gate.wait
            block.call
          rescue CommsSending::Refused, StandardError => error
            error
          end
        end
      end
      sleep 0.05
      gate.count_down
      threads.map(&:value)
    end
    drained = []
    drained << calls.pop until calls.empty?
    [ drained, results ]
  end

end
