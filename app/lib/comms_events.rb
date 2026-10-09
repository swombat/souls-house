# Applies one signed connector event to a comms ServiceConnection. Same rule
# as RunnerEnrollment: every check under the connection's row lock first,
# then the nonce, then the change, all in one transaction. A refusal leaves
# the nonce table and the comms tables untouched.
module CommsEvents

  MAX_BATCH = 200
  NONCE_RETENTION = (CommsSignature::MAX_SKEW * 2 + 60).seconds
  MAX_QR_LIFETIME = 5.minutes
  MESSAGE_FIELDS = %w[provider_message_id chat sender_id sender_name sent_at body media_kind caption from_me].freeze
  CHAT_FIELDS = %w[provider_chat_id name kind last_activity_at].freeze

  # Connector status → ServiceConnection status. A phone-side logout needs the
  # owner to pair again, which the house already calls reauthorizing.
  STATUS_CHANGES = {
    "connected" => { from: %w[pairing connected], to: "connected" },
    "logged_out" => { from: %w[pairing connected], to: "reauthorizing" }
  }.freeze

  class Refused < StandardError

    attr_reader :code, :status

    def initialize(code, status)
      @code = code
      @status = status
      super(code.to_s)
    end

  end

  module_function

  def receive!(connection, event, nonce:, now: Time.current)
    raise Refused.new(:bad_event, :unprocessable_entity) unless event.is_a?(Hash)

    connection.with_lock do
      case event["type"]
      when "chat.upsert"
        require_status!(connection, %w[connected])
        chats = batch!(event["chats"])
        consume_nonce!(connection, nonce, now)
        chats.each { |chat| upsert_chat!(connection, chat) }
      when "message.upsert"
        require_status!(connection, %w[connected])
        messages = batch!(event["messages"])
        consume_nonce!(connection, nonce, now)
        messages.each { |message| upsert_message!(connection, message) }
      when "status.changed"
        change = STATUS_CHANGES[event["status"]] || raise(Refused.new(:unknown_status, :unprocessable_entity))
        require_status!(connection, change.fetch(:from))
        consume_nonce!(connection, nonce, now)
        connection.update!(status: change.fetch(:to), pairing_qr: nil, pairing_qr_expires_at: nil, pairing_qr_issued_at: nil)
      when "pairing.qr"
        require_status!(connection, %w[pairing])
        code, expires_at, issued_at = event["code"].to_s, time(event["expires_at"]), time(event["issued_at"])
        raise Refused.new(:bad_qr, :unprocessable_entity) if code.blank? || expires_at.nil? || issued_at.nil?
        raise Refused.new(:bad_qr, :unprocessable_entity) unless expires_at > now && expires_at <= now + MAX_QR_LIFETIME
        # A fresh nonce does not make events ordered: an older code arriving
        # after its replacement must not overwrite it.
        if connection.pairing_qr_issued_at && issued_at <= connection.pairing_qr_issued_at
          raise Refused.new(:stale_qr, :conflict)
        end
        consume_nonce!(connection, nonce, now)
        connection.update!(pairing_qr: code, pairing_qr_expires_at: expires_at, pairing_qr_issued_at: issued_at)
      else
        raise Refused.new(:unknown_event, :unprocessable_entity)
      end
    end
  end

  def require_status!(connection, allowed)
    raise Refused.new(:connection_not_accepting, :conflict) unless allowed.include?(connection.status)
  end

  def batch!(items)
    raise Refused.new(:bad_batch, :unprocessable_entity) unless items.is_a?(Array) && items.all?(Hash)
    raise Refused.new(:batch_too_large, :content_too_large) if items.size > MAX_BATCH

    items
  end

  def consume_nonce!(connection, nonce, now)
    connection.comms_request_nonces.where(created_at: ...(now - NONCE_RETENTION)).delete_all
    connection.comms_request_nonces.create!(nonce:, created_at: now)
  rescue ActiveRecord::RecordNotUnique
    raise CommsSignature::Invalid.new(:replayed_nonce)
  end

  def upsert_chat!(connection, attributes)
    attributes = attributes.slice(*CHAT_FIELDS)
    chat = connection.comms_chats.find_or_initialize_by(provider_chat_id: attributes["provider_chat_id"].to_s)
    chat.assign_attributes(
      name: attributes.key?("name") ? attributes["name"] : chat.name,
      kind: attributes.key?("kind") ? attributes["kind"] : chat.kind,
      last_activity_at: [ chat.last_activity_at, time(attributes["last_activity_at"]) ].compact.max
    )
    chat.save! if chat.changed?
    chat
  end

  def upsert_message!(connection, attributes)
    attributes = attributes.slice(*MESSAGE_FIELDS)
    sent_at = time(attributes["sent_at"]) || raise(Refused.new(:bad_message, :unprocessable_entity))
    chat = connection.comms_chats.find_or_create_by!(provider_chat_id: attributes["chat"].to_s)
    # Messages are immutable once stored: the first delivery wins, and any
    # later delivery of the same provider id (a retry, a reordered retry, or
    # an edit) is ignored. Edits and deletions are not modelled in milestone 1.
    message = connection.comms_messages.find_or_initialize_by(provider_message_id: attributes["provider_message_id"].to_s)
    return message if message.persisted?

    message.assign_attributes(
      comms_chat: chat,
      sender_id: attributes["sender_id"],
      sender_name: attributes["sender_name"],
      sent_at: sent_at,
      body: attributes["body"],
      media_kind: attributes["media_kind"],
      caption: attributes["caption"],
      from_me: attributes["from_me"] == true
    )
    message.save!
    # A message this connection sent: attribute it to its send record if the
    # connector's acknowledgement is already in (echo after ack). Otherwise
    # the acknowledgement links it when it arrives (CommsSending.complete!).
    CommsSending.link_message!(connection, message)
    chat.update!(last_activity_at: sent_at) if chat.last_activity_at.nil? || sent_at > chat.last_activity_at
    message
  end

  def time(value)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

end
