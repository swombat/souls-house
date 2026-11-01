# A resident sending one text through a comms connection, as the
# connection's owner (WhatsApp spec §5). Provider-neutral: a provider whose
# adapter implements new_send_message_id, send_generation, send_text and
# own_sender can
# send (WhatsApp now; Telegram plugs in with its own adapter methods,
# proposal 2026-10-11 §8), and only once it is listed in
# COMMS_SEND_PROVIDERS.
#
# Three steps, each holding the connection's row lock only briefly and
# never across the connector call:
#
# 1. claim!: under the lock, find this (connection, resident,
#    client_request_id) or create it. An existing claim is returned as it is
#    (same chat and text) or refused (409); it never counts against pacing
#    again. A new claim needs the connection connected, the access row
#    enabled with can_send and room in the pacing, all checked under the
#    lock, so concurrent requests cannot pass the cap together. The claim
#    records the provider message id (chosen here) and the connection's
#    session generation. The unique index is the backstop.
# 2. dispatch!: under the lock again, re-check connected, the grant, the
#    gate, the generation and pacing. A send refused here is failed with
#    refused_at_dispatch_<why> and the connector is never called. Otherwise
#    it becomes `unknown` with dispatched_at, and that commits before the
#    connector is called: from here a crash, a timeout or a lost answer
#    leaves it unknown.
# 3. the connector call, outside any lock; then its outcome is recorded and
#    the echoed message linked, under the lock. Only the connector's
#    explicit answer makes a send sent or failed. Nothing ever retries an
#    unknown send.
#
# Pacing counts sends by when they were handed to the connector
# (dispatched_at), so a backlog of old pending claims retried together is
# paced like new sends. A send is charged once. At claim time a pending
# claim made inside the window also counts, as a reservation, so concurrent
# new requests over the cap are refused with 429 up front.
module CommsSending

  # Provisional pacing per connection, for Daniel to adjust (spec §5).
  PER_MINUTE = 6
  PER_DAY = 100
  PROVIDERS_ENV = "COMMS_SEND_PROVIDERS".freeze

  # Added to a connection's runtime notes for a resident that may send
  # (ServiceConnection#runtime_notes), in place of "no way to send".
  RUNTIME_NOTES = [
    "The owner has let you send: soulshouse-comms send --chat <id> --text - (text on stdin) [--request-id <id>]. " \
    "The message goes out AS THE OWNER, from the owner's own account, and shows on the owner's phone. " \
    "It is recorded with your name, and the owner can read every send.",
    "Send only into chats that already exist, one chat per send, text only. No bulk, unsolicited or broadcast messages: " \
    "sending is what gets an account banned. Limits are #{PER_MINUTE} a minute and #{PER_DAY} a day per connection.",
    "A send whose status is unknown may or may not have gone. Never resend it automatically: read the chat first, " \
    "and ask the owner if unsure. Retry only with the same request id, which never sends twice."
  ].freeze

  class Refused < StandardError

    attr_reader :code, :status

    def initialize(code, status, message = nil)
      @code = code
      @status = status
      super(message || code.to_s)
    end

  end

  Result = Data.define(:send, :created)

  module_function

  # The gate: providers sending is switched on for. Empty by default, so
  # nothing about sending is offered or accepted. A provider listed without
  # a dispatcher (Telegram, today) stays off.
  def enabled_providers
    ENV[PROVIDERS_ENV].to_s.split(",").map(&:strip).reject(&:empty?).select { |provider| dispatchable?(provider) }
  end

  def available_for?(connection)
    connection.credential_strategy == "connector" && enabled_providers.include?(connection.provider)
  end

  def dispatchable?(provider)
    adapter = Services::Definition.fetch(provider).adapter
    %i[new_send_message_id send_generation send_text own_sender].all? { |method| adapter.respond_to?(method) }
  rescue Services::Definition::UnknownProvider
    false
  end

  def request!(connection:, agent:, chat:, text:, client_request_id:, now: Time.current)
    send, created = claim!(connection:, agent:, chat:, text:, client_request_id:, now:)
    # A claim still `pending` was never dispatched (the request died between
    # claim and dispatch), so the connector has not been called and a retry
    # may dispatch it. dispatch! moves it out of `pending` under the lock, so
    # concurrent retries still make at most one connector call.
    send = deliver!(send) if send.status == "pending"
    Result.new(send:, created:)
  end

  def claim!(connection:, agent:, chat:, text:, client_request_id:, now: Time.current)
    connection.transaction do
      connection.lock!
      existing = connection.comms_sends.find_by(agent_id: agent.id, client_request_id: client_request_id)
      next [ require_same_request!(existing, chat, text), false ] if existing

      require_sendable!(connection, agent)
      require_claim_room!(connection, now)

      adapter = connection.definition.adapter
      send = connection.comms_sends.create!(
        agent: agent, comms_chat: chat, text: text, client_request_id: client_request_id,
        status: "pending", requested_at: now,
        provider_message_id: adapter.new_send_message_id,
        connection_generation: adapter.send_generation(connection)
      )
      [ send, true ]
    end
  rescue ActiveRecord::RecordNotUnique
    # Only reachable if a claim got past the lock: the index decides.
    existing = connection.comms_sends.find_by!(agent_id: agent.id, client_request_id: client_request_id)
    [ require_same_request!(existing, chat, text), false ]
  end

  def deliver!(send)
    return send.reload unless dispatch!(send)

    complete!(send, send.service_connection.definition.adapter.send_text(send))
  end

  # True when the send may go to the connector. A send refused here is
  # failed with the reason; the connector is never called.
  def dispatch!(send, now: Time.current)
    connection = send.service_connection
    connection.transaction do
      connection.lock!
      send.lock!
      next false unless send.status == "pending"

      begin
        require_sendable!(connection, send.agent)
        unless connection.definition.adapter.send_generation(connection) == send.connection_generation
          raise Refused.new(:stale_generation, :conflict)
        end
        require_dispatch_room!(connection, now)
      rescue Refused => refusal
        send.update!(status: "failed", error_code: "refused_at_dispatch_#{refusal.code}")
        next false
      end
      # Who the message will be from, fixed while the lock holds and the
      # session is the one checked above: a late acknowledgement records it
      # under this, even if the connection names another account by then.
      sender = connection.definition.adapter.own_sender(connection)
      send.update!(status: "unknown", dispatched_at: now,
                   sender_id: sender["sender_id"], sender_name: sender["sender_name"])
      true
    end
  end

  def complete!(send, outcome)
    connection = send.service_connection
    connection.transaction do
      connection.lock!
      send.lock!
      # Only an unknown send (the one this call dispatched) takes an outcome.
      next unless send.status == "unknown"

      attributes = { status: outcome.status, error_code: outcome.error_code, error_reason: outcome.error_reason }
      if outcome.status == "sent"
        attributes[:provider_message_id] = outcome.provider_message_id
        attributes[:sent_at] = outcome.sent_at
      end
      send.update!(attributes)
      record_own_message!(send) if outcome.status == "sent"
      link_echo!(send)
    end
    send
  end

  # WhatsApp does not echo a message back to the linked device that sent it
  # (it reaches the owner's other devices), so attribution and the message's
  # presence in the chat cannot wait for an echo. On a `sent` outcome Rails
  # stores the message itself, through the same upsert the connector's
  # events use: keyed on (chat, provider message id), so an echo that does
  # arrive, before or after, is the same row, and later edits and deletions
  # apply to it as to any message. The link is made by CommsMessage's
  # after_create, or by link_echo! when the echo came first.
  def record_own_message!(send)
    connection = send.service_connection
    # The sender fixed at dispatch, never the connection's identity now.
    sender = { "sender_id" => send.sender_id, "sender_name" => send.sender_name }
    CommsEvents.upsert_message!(connection, sender.merge(
      "provider_message_id" => send.provider_message_id,
      "chat" => send.comms_chat.provider_chat_id,
      "sent_at" => send.sent_at || send.dispatched_at,
      "body" => send.text
    ))
  end

  # The acknowledgement side of echo-before-ack: the echo is already stored.
  def link_echo!(send)
    return if send.comms_message

    message = send.comms_chat.comms_messages.find_by(provider_message_id: send.provider_message_id, comms_send_id: nil)
    message&.update_columns(comms_send_id: send.id)
  end

  # The echo side of ack-before-echo (CommsMessage after_create, under the
  # connection's lock in CommsEvents). The message id was chosen by Rails
  # and is unique in the chat, so the match is the send's own message.
  def link_message!(message)
    return if message.comms_send_id

    send = CommsSend.where(comms_chat_id: message.comms_chat_id, provider_message_id: message.provider_message_id)
                    .where.missing(:comms_message).first
    message.update_columns(comms_send_id: send.id) if send
  end

  def require_same_request!(existing, chat, text)
    return existing if existing.same_request?(chat, text)

    raise Refused.new(:client_request_id_reused, :conflict, "This client_request_id was used for a different message")
  end

  # Read under the connection's lock, with the access row locked second.
  # Effective, not just enabled: a guest's send waits for its home's
  # approval, at claim and again at dispatch (re-asking can land between).
  def require_sendable!(connection, agent)
    raise Refused.new(:not_available, :not_found, "Sending is not available for this connection") unless available_for?(connection)
    raise Refused.new(:not_connected, :conflict, "This service connection is not currently connected") unless connection.status == "connected"

    access = connection.agent_service_accesses.lock.find_by(agent_id: agent.id)
    raise Refused.new(:send_not_granted, :forbidden, "This resident may read this connection but not send through it") unless access&.effective? && access.can_send?
  end

  # At claim: sends dispatched inside the window, plus pending claims made
  # inside it (each will need a slot when it dispatches).
  def require_claim_room!(connection, now)
    sends = connection.comms_sends
    pacing_refusal! if over_pace?(now) { |since| sends.where(dispatched_at: since..).or(sends.where(status: "pending", requested_at: since..)) }
  end

  # At dispatch: only sends actually handed to the connector inside the
  # window. The send being dispatched is pending, so it is not among them.
  def require_dispatch_room!(connection, now)
    pacing_refusal! if over_pace?(now) { |since| connection.comms_sends.where(dispatched_at: since..) }
  end

  def over_pace?(now)
    yield(now - 1.minute).count >= PER_MINUTE || yield(now - 1.day).count >= PER_DAY
  end

  def pacing_refusal!
    raise Refused.new(:rate_limited, :too_many_requests, "This connection's send limit is reached (#{PER_MINUTE}/minute, #{PER_DAY}/day)")
  end

end
