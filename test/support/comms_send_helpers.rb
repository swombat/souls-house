# Shared setup for the comms sending tests (WhatsApp spec §5): a team account
# whose WhatsApp is owned by users(:admin), with users(:owner) as an account
# admin who does not own it; a resident with read access; a chat; sending
# and a fake connector that
# records every send_text call and answers as told.
module CommsSendHelpers

  def setup_comms_send
    @account = accounts(:team)
    @owner = users(:admin)
    @account_admin = users(:owner)
    # External, so its resident key authenticates (ApiKey.authenticate refuses
    # keys of hosted residents).
    @agent = @account.agents.create!(name: "Comms Sender", model_id: "openrouter/auto", runtime: "external")
    @connection = build_whatsapp_connection(@account, @owner)
    @access = @agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)
    @chat = @connection.comms_chats.create!(provider_chat_id: "447700900123@s.whatsapp.net", name: "Alice", kind: "direct")
  end

  def teardown_comms_send; end

  # Sending unavailable for every provider, as for a provider with no
  # dispatcher: what the house does when it cannot send.
  def without_sending(&block)
    CommsSending.stub(:enabled_providers, [], &block)
  end

  def build_whatsapp_connection(account, owner, status: "connected")
    attributes = Services::Definition.fetch("whatsapp").adapter.connection_attributes(credentials: {}, user: owner)
    account.service_connections.create!(
      connected_by_user: owner, provider: "whatsapp", management_scope: "personal", status: status,
      label: attributes[:label], credential_kind: attributes[:credential_kind],
      credential_fingerprint: attributes[:credential_fingerprint], credential_metadata: attributes[:credential_metadata],
      credential_payload_hash: attributes[:credential_payload]
    )
  end

  def grant_send!(access = @access)
    access.change_send_grant!(true, actor: @owner)
  end

  # Replaces CommsConnector.send_text for the block. `answer` is called with
  # the send and returns a CommsConnector::SendOutcome (default: sent, with
  # the message id the house chose). Returns the send ids the connector saw.
  def with_fake_connector(answer = nil, &block)
    calls = Queue.new
    answer ||= ->(send) { sent_outcome(send) }
    CommsConnector.stub(:send_text, ->(send) { calls << send.id; answer.call(send) }, &block)
    drained = []
    drained << calls.pop until calls.empty?
    drained
  end

  def sent_outcome(send, provider_message_id: send.provider_message_id)
    CommsConnector::SendOutcome.new(status: "sent", provider_message_id: provider_message_id,
                                    sent_at: Time.iso8601("2026-10-24T12:00:00Z"), error_code: nil, error_reason: nil)
  end

  # Committed rows, for the threaded tests: a WhatsApp connection with one
  # chat, a resident with read access, and teardown that removes them.
  def committed_whatsapp_fixture(agent:, owner:)
    connection = build_whatsapp_connection(agent.account, owner)
    access = agent.agent_service_accesses.create!(service_connection: connection, enabled: true)
    chat = connection.comms_chats.create!(provider_chat_id: "447700900123@s.whatsapp.net", kind: "direct")
    [ connection, access, chat ]
  end

  def remove_committed_whatsapp_fixture(connection)
    CommsMessage.where(service_connection_id: connection.id).delete_all
    CommsSend.where(service_connection_id: connection.id).delete_all
    CommsSendGrantEvent.where(service_connection_id: connection.id).delete_all
    AgentServiceAccess.where(service_connection_id: connection.id).delete_all
    CommsChat.where(service_connection_id: connection.id).delete_all
    ServiceConnection.where(id: connection.id).delete_all
  end

  # Runs the block in its own thread with its own database connection.
  # Returns [:ok, value] or [:error, exception], so a test must say which it
  # expects: an exception is never mistaken for success.
  def in_thread(&block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        [ :ok, block.call ]
      rescue StandardError => error
        [ :error, error ]
      end
    end
  end

  def assert_thread_ok(thread)
    assert thread.join(10), "thread did not finish"
    outcome, value = thread.value
    assert_equal :ok, outcome, -> { "thread raised #{value.class}: #{value.message}" }
    value
  end

  def assert_thread_raised(thread, error_class)
    assert thread.join(10), "thread did not finish"
    outcome, value = thread.value
    assert_equal :error, outcome, -> { "thread returned #{value.inspect} instead of raising #{error_class}" }
    assert_kind_of error_class, value
    value
  end

end
