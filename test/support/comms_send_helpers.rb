# Shared setup for the WhatsApp sending tests (spec §5): a team account whose
# WhatsApp is owned by users(:admin), with users(:owner) as an account admin
# who does not own it; a resident with read access; a chat; and a fake
# connector that records every send_text call and answers as told.
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
  # the message ID the house chose). Returns the sends the connector saw.
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
                                    sent_at: Time.iso8601("2026-10-09T12:00:00Z"), error_code: nil)
  end

end
