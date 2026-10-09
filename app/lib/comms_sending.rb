# A resident sending one text through a comms (WhatsApp) connection, as the
# connection's owner (spec §5). Three steps, each with the connection's row
# lock held only briefly and never across the connector call:
#
# 1. claim!: under the lock, find this (connection, resident,
#    client_request_id) or create it. An existing claim is returned as it is
#    (same chat and text) or refused (409); it never counts against the rate
#    limit and never calls the connector again. A new claim needs the
#    connection connected, the access row enabled with can_send, and room in
#    the rate limit, all checked under the lock, so concurrent requests
#    cannot pass the cap together. The unique index on the claim is the
#    backstop if anything gets past the lock.
# 2. dispatch!: under the lock again, re-check connected, the grant and the
#    rate limit (a grant withdrawn after the claim, or a limit reached since,
#    stops the send: failed, refused at dispatch, no connector call), then
#    mark the send `unknown` with dispatched_at and commit. From here a
#    crash, a timeout or a lost answer leaves it unknown.
#
# The rate limit counts sends by when they were handed to the connector
# (dispatched_at), so a backlog of old pending claims retried together is
# paced like new sends. A send is charged once: a retry of one already
# dispatched neither calls the connector nor counts again. At claim time a
# pending claim made inside the window also counts, as a reservation, so
# concurrent new requests over the cap are refused with 429 up front.
# 3. call the connector outside any lock, then record its outcome and link
#    the echoed message under the lock. Only the connector's explicit answer
#    makes a send sent or failed. Nothing retries an unknown send.
module CommsSending

  # Provisional limits for Daniel to adjust (spec §5).
  PER_MINUTE = 6
  PER_DAY = 100

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

  def request!(connection:, agent:, chat:, text:, client_request_id:, now: Time.current)
    send, created = claim!(connection:, agent:, chat:, text:, client_request_id:, now:)
    # A claim still `pending` was never dispatched (the request died between
    # claim and dispatch), so the connector has not been called and a retry
    # may dispatch it. dispatch! moves it out of `pending` under the lock, so
    # concurrent retries still make at most one connector call.
    send = deliver!(send) if created || send.status == "pending"
    Result.new(send:, created:)
  end

  def claim!(connection:, agent:, chat:, text:, client_request_id:, now: Time.current)
    connection.transaction do
      connection.lock!
      existing = connection.comms_sends.find_by(agent_id: agent.id, client_request_id: client_request_id)
      if existing
        raise Refused.new(:client_request_id_reused, :conflict, "This client_request_id was used for a different message") unless existing.same_request?(chat, text)

        next [ existing, false ]
      end

      require_sendable!(connection, agent)
      require_rate_room!(connection, now)

      send = connection.comms_sends.create!(
        agent: agent, comms_chat: chat, text: text, client_request_id: client_request_id,
        status: "pending", requested_at: now
      )
      send.update_columns(provider_message_id: CommsSend.provider_message_id_for(connection.id, send.id))
      [ send, true ]
    end
  rescue ActiveRecord::RecordNotUnique
    # Only reachable if a claim got past the lock: the index decides.
    existing = connection.comms_sends.find_by!(agent_id: agent.id, client_request_id: client_request_id)
    raise Refused.new(:client_request_id_reused, :conflict, "This client_request_id was used for a different message") unless existing.same_request?(chat, text)

    [ existing, false ]
  end

  def deliver!(send)
    return send unless dispatch!(send)

    complete!(send, CommsConnector.send_text(send))
  end

  # Returns true when the send may go to the connector. A send refused here
  # is failed with the reason; the connector was never called.
  def dispatch!(send)
    connection = send.service_connection
    connection.transaction do
      connection.lock!
      send.lock!
      next false unless send.status == "pending"

      now = Time.current
      begin
        require_sendable!(connection, send.agent)
        require_dispatch_room!(connection, now)
      rescue Refused => refusal
        send.update!(status: "failed", error_code: "refused_at_dispatch_#{refusal.code}")
        next false
      end
      send.update!(status: "unknown", dispatched_at: now)
      true
    end
  end

  def complete!(send, outcome)
    connection = send.service_connection
    connection.transaction do
      connection.lock!
      send.lock!
      attributes = { status: outcome.status, error_code: outcome.error_code }
      if outcome.status == "sent"
        attributes[:provider_message_id] = outcome.provider_message_id
        attributes[:sent_at] = outcome.sent_at || Time.current
      end
      send.update!(attributes)
      link_echo!(send)
    end
    send
  end

  # The acknowledgement side of echo-before-ack: the echo was stored first.
  def link_echo!(send)
    return if send.provider_message_id.blank?

    message = send.service_connection.comms_messages.find_by(provider_message_id: send.provider_message_id)
    link!(message, send) if message
  end

  # The echo side of ack-before-echo, called by CommsEvents under the
  # connection's lock when a from_me message is stored.
  def link_message!(connection, message)
    return unless message.from_me? && message.comms_send_id.nil?

    send = connection.comms_sends.find_by(provider_message_id: message.provider_message_id)
    link!(message, send) if send
  end

  def link!(message, send)
    return unless message.from_me? && message.comms_send_id.nil? && message.comms_chat_id == send.comms_chat_id

    # Attribution only: the stored body is never rewritten.
    message.update_columns(comms_send_id: send.id)
  end

  def require_sendable!(connection, agent)
    raise Refused.new(:not_connected, :conflict, "This service connection is not currently connected") unless connection.status == "connected"

    access = connection.agent_service_accesses.lock.find_by(agent_id: agent.id)
    raise Refused.new(:send_not_granted, :forbidden, "This resident may read this connection but not send through it") unless access&.enabled? && access.can_send?
  end

  # At claim: sends dispatched inside the window, plus pending claims made
  # inside it (each will need a slot when it dispatches).
  def require_rate_room!(connection, now)
    rate_refusal! if over_rate?(now) { |since| charged_or_reserved(connection, since) }
  end

  # At dispatch, under the connection's lock: only sends actually handed to
  # the connector inside the window. The send being dispatched is pending,
  # so it is not among them.
  def require_dispatch_room!(connection, now)
    rate_refusal! if over_rate?(now) { |since| connection.comms_sends.where(dispatched_at: since..) }
  end

  def over_rate?(now)
    yield(now - 1.minute).count >= PER_MINUTE || yield(now - 1.day).count >= PER_DAY
  end

  def charged_or_reserved(connection, since)
    sends = connection.comms_sends
    sends.where(dispatched_at: since..).or(sends.where(status: "pending", requested_at: since..))
  end

  def rate_refusal!
    raise Refused.new(:rate_limited, :too_many_requests, "This connection's send limit is reached (#{PER_MINUTE}/minute, #{PER_DAY}/day)")
  end

end
