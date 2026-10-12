# Applies one signed connector event to a comms ServiceConnection. Same rule
# as RunnerEnrollment: every check under the connection's row lock first,
# then the nonce, then the change, all in one transaction. A refusal leaves
# the nonce table and the comms tables untouched.
#
# Telegram (proposal 2026-10-11) adds:
# - message identity per chat (typed peers), edits ordered by the provider's
#   edit time, and deletions as tombstones that nothing can undo;
# - per-chat sync state and checkpoints;
# - login events bound to the connection's login generation, so an event
#   from an older or cancelled attempt is refused;
# - the pool's availability for the connection;
# - an optional event sequence number: Rails records the highest one it has
#   committed and returns it, which is the connector's acknowledgement (§5a).
module CommsEvents

  MAX_BATCH = 200
  NONCE_RETENTION = (CommsSignature::MAX_SKEW * 2 + 60).seconds
  MAX_QR_LIFETIME = 5.minutes
  MESSAGE_FIELDS = %w[provider_message_id chat sender_id sender_name sent_at body media_kind caption edited_at].freeze
  EDIT_FIELDS = %w[provider_message_id chat body caption edited_at].freeze
  CHAT_FIELDS = %w[provider_chat_id name kind last_activity_at sync_state].freeze
  LOGIN_FAILURES = %w[expired password_invalid flood_wait failed].freeze
  LOGIN_EVENTS = %w[pairing.qr login.qr login.password_required login.failed status.changed].freeze
  # Refusals that mean "this authenticated lifecycle event is out of date"
  # (an older login attempt, a replaced or expired QR, a login that already
  # finished), not "this event is wrong". Sequenced, they are acknowledged
  # as no-ops so the ordered outbox behind them keeps moving; nothing about
  # them is applied.
  OBSOLETE = %i[stale_generation stale_qr expired_qr connection_not_accepting].freeze

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

  class SequenceGap < Refused

    attr_reader :committed_seq

    def initialize(committed_seq)
      @committed_seq = committed_seq
      super(:sequence_gap, :conflict)
    end

  end

  module_function

  # Returns nil for an unsequenced event. For a sequenced one, returns
  # { committed_seq:, skipped: } where skipped names why an obsolete
  # lifecycle event was acknowledged without being applied.
  def receive!(connection, event, nonce:, now: Time.current)
    raise Refused.new(:bad_event, :unprocessable_entity) unless event.is_a?(Hash)

    seq = sequence(event)
    connection.with_lock do
      # Sequenced events are applied in order, exactly once: one already
      # committed is acknowledged again without being reapplied, and one
      # past a gap is refused so the connector resends from the gap.
      if seq
        return { committed_seq: connection.comms_event_seq } if seq <= connection.comms_event_seq
        raise SequenceGap.new(connection.comms_event_seq) if seq > connection.comms_event_seq + 1
      end

      begin
        apply!(connection, event, nonce:, now:)
      rescue Refused => e
        raise unless seq && LOGIN_EVENTS.include?(event["type"]) && OBSOLETE.include?(e.code)

        consume_nonce!(connection, nonce, now)
        record_sequence!(connection, seq)
        return { committed_seq: seq, skipped: e.code.to_s }
      end
      record_sequence!(connection, seq) if seq
    end
    seq ? { committed_seq: connection.comms_event_seq } : nil
  end

  def apply!(connection, event, nonce:, now:)
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
    when "message.edit"
      require_status!(connection, %w[connected])
      edits = batch!(event["messages"])
      consume_nonce!(connection, nonce, now)
      edits.each { |edit| apply_edit!(connection, edit) }
    when "message.delete"
      require_status!(connection, %w[connected])
      deletions = batch!(event["deletions"])
      unresolved = event["unresolved"].to_i
      raise Refused.new(:bad_batch, :unprocessable_entity) if unresolved.negative?
      consume_nonce!(connection, nonce, now)
      deletions.each { |deletion| apply_deletion!(connection, deletion, now) }
      record_unresolved_deletions!(connection, unresolved) if unresolved.positive?
    when "sync.checkpoint"
      require_status!(connection, %w[connected])
      chats = batch!(event["chats"])
      consume_nonce!(connection, nonce, now)
      chats.each { |checkpoint| apply_checkpoint!(connection, checkpoint) }
    when "status.changed"
      change = STATUS_CHANGES[event["status"]] || raise(Refused.new(:unknown_status, :unprocessable_entity))
      require_status!(connection, change.fetch(:from))
      # Every Telegram status change (finishing a sign-in, a refresh of the
      # identity once connected, a Telegram-side logout) must name the
      # attempt it belongs to, so nothing from an older attempt can change
      # who this connection is. WhatsApp's pairing has no generations.
      if event.key?("generation") || connection.provider == "telegram"
        require_generation!(connection, event)
      end
      consume_nonce!(connection, nonce, now)
      attributes = { status: change.fetch(:to), pairing_qr: nil, pairing_qr_expires_at: nil, pairing_qr_issued_at: nil }
      attributes[:connector_state] = connection.connector_state.to_h.except("login")
      attributes.merge!(identity_attributes(event["identity"])) if change.fetch(:to) == "connected" && event["identity"].is_a?(Hash)
      connection.update!(attributes)
    when "pairing.qr", "login.qr"
      require_status!(connection, %w[pairing])
      if event["type"] == "login.qr" || event.key?("generation") || connection.provider == "telegram"
        require_generation!(connection, event)
      end
      code, expires_at, issued_at = event["code"].to_s, time(event["expires_at"]), time(event["issued_at"])
      raise Refused.new(:bad_qr, :unprocessable_entity) if code.blank? || expires_at.nil? || issued_at.nil?
      raise Refused.new(:expired_qr, :unprocessable_entity) unless expires_at > now
      raise Refused.new(:bad_qr, :unprocessable_entity) unless expires_at <= now + MAX_QR_LIFETIME
      # A fresh nonce does not make events ordered: an older code arriving
      # after its replacement must not overwrite it.
      if connection.pairing_qr_issued_at && issued_at <= connection.pairing_qr_issued_at
        raise Refused.new(:stale_qr, :conflict)
      end
      consume_nonce!(connection, nonce, now)
      connection.update!(pairing_qr: code, pairing_qr_expires_at: expires_at, pairing_qr_issued_at: issued_at)
    when "login.password_required"
      require_status!(connection, %w[pairing])
      require_generation!(connection, event)
      consume_nonce!(connection, nonce, now)
      login = { "step" => "password", "hint" => event["hint"].to_s.first(200).presence }.compact
      connection.update!(
        connector_state: connection.connector_state.to_h.merge("login" => login),
        pairing_qr: nil, pairing_qr_expires_at: nil, pairing_qr_issued_at: nil
      )
    when "login.failed"
      require_status!(connection, %w[pairing])
      require_generation!(connection, event)
      code = event["code"].to_s
      raise Refused.new(:unknown_failure, :unprocessable_entity) unless LOGIN_FAILURES.include?(code)
      consume_nonce!(connection, nonce, now)
      login = connection.login_state.slice("step", "hint")
      login.delete("step") unless code == "password_invalid"
      login["error"] = code
      login["retry_after"] = event["retry_after"].to_i if code == "flood_wait" && event["retry_after"].to_i.positive?
      login["at"] = now.utc.iso8601
      attributes = { connector_state: connection.connector_state.to_h.merge("login" => login) }
      attributes.merge!(pairing_qr: nil, pairing_qr_expires_at: nil, pairing_qr_issued_at: nil) unless code == "password_invalid"
      connection.update!(attributes)
    when "connector.availability"
      state = event["state"].to_s
      raise Refused.new(:unknown_availability, :unprocessable_entity) unless ServiceConnection::CONNECTOR_AVAILABILITY.include?(state)
      consume_nonce!(connection, nonce, now)
      availability = { "state" => state, "reason" => event["reason"].to_s.first(200).presence,
                       "since" => time(event["since"])&.utc&.iso8601, "retry_after" => event["retry_after"]&.to_i }.compact
      connection.update!(connector_state: connection.connector_state.to_h.merge("availability" => availability))
    else
      raise Refused.new(:unknown_event, :unprocessable_entity)
    end
  end

  def sequence(event)
    return unless event.key?("seq")

    value = event["seq"]
    raise Refused.new(:bad_seq, :unprocessable_entity) unless value.is_a?(Integer) && value.positive?

    value
  end

  def record_sequence!(connection, seq)
    connection.update_columns(comms_event_seq: seq)
  end

  def require_status!(connection, allowed)
    raise Refused.new(:connection_not_accepting, :conflict) unless allowed.include?(connection.status)
  end

  def require_generation!(connection, event)
    raise Refused.new(:stale_generation, :conflict) unless event["generation"] == connection.login_generation
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

  def identity_attributes(identity)
    user_id = identity["user_id"].to_s.presence
    username = identity["username"].to_s.presence
    display = identity["display_name"].to_s.presence
    shown = [ display, (username && "@#{username}") ].compact.join(" ").presence
    { external_subject_id: user_id, external_identity: shown&.first(200) }.compact
  end

  def upsert_chat!(connection, attributes)
    attributes = attributes.slice(*CHAT_FIELDS)
    chat = connection.comms_chats.find_or_initialize_by(provider_chat_id: attributes["provider_chat_id"].to_s)
    chat.assign_attributes(
      name: attributes.key?("name") ? attributes["name"] : chat.name,
      kind: attributes.key?("kind") ? attributes["kind"] : chat.kind,
      last_activity_at: [ chat.last_activity_at, time(attributes["last_activity_at"]) ].compact.max
    )
    chat.sync_state = merged_sync_state(chat.sync_state, attributes["sync_state"]) if attributes.key?("sync_state")
    chat.save! if chat.changed?
    chat
  end

  # The connector's word on sync scope and coverage. synced_through only moves
  # forward; deletions_not_applied is a count the connector owns.
  def merged_sync_state(current, incoming)
    raise Refused.new(:bad_sync_state, :unprocessable_entity) unless incoming.is_a?(Hash)

    incoming = incoming.slice(*CommsChat::SYNC_FIELDS)
    if incoming.key?("reason") && incoming["reason"].present? && !CommsChat::UNSYNCED_REASONS.include?(incoming["reason"])
      raise Refused.new(:bad_sync_state, :unprocessable_entity)
    end
    merged = current.to_h.merge(incoming.except("synced_through"))
    merged["history_from"] = time(merged["history_from"])&.utc&.iso8601 if merged.key?("history_from")
    through = [ time(current.to_h["synced_through"]), time(incoming["synced_through"]) ].compact.max
    merged["synced_through"] = through.utc.iso8601 if through
    merged.compact
  end

  def apply_checkpoint!(connection, checkpoint)
    chat = connection.comms_chats.find_by(provider_chat_id: checkpoint["provider_chat_id"].to_s)
    return unless chat

    through = time(checkpoint["synced_through"]) || raise(Refused.new(:bad_checkpoint, :unprocessable_entity))
    current = time(chat.sync_state.to_h["synced_through"])
    return if current && current >= through

    chat.update!(sync_state: chat.sync_state.to_h.merge("synced_through" => through.utc.iso8601))
  end

  def upsert_message!(connection, attributes)
    attributes = attributes.slice(*MESSAGE_FIELDS)
    sent_at = time(attributes["sent_at"]) || raise(Refused.new(:bad_message, :unprocessable_entity))
    chat = connection.comms_chats.find_or_create_by!(provider_chat_id: attributes["chat"].to_s)
    # The first delivery of a message wins its content; a later delivery of
    # the same id in the same chat (a retry, a backfill page) changes it only
    # if it carries a newer edit than the one stored. A tombstone stays a
    # tombstone. A placeholder (an edit or deletion that came first) gets its
    # sender and time from the original, and keeps its newer content.
    message = chat.comms_messages.find_or_initialize_by(provider_message_id: attributes["provider_message_id"].to_s)
    edited_at = time(attributes["edited_at"])
    if message.persisted?
      fill_placeholder!(message, attributes, sent_at) if message.placeholder?
      apply_content!(message, attributes, edited_at) unless message.deleted?
      return message
    end

    message.assign_attributes(
      service_connection: connection,
      sender_id: attributes["sender_id"],
      sender_name: attributes["sender_name"],
      sent_at: sent_at,
      body: attributes["body"],
      media_kind: attributes["media_kind"],
      caption: attributes["caption"],
      edited_at: edited_at,
      edit_version: edited_at && version_of(edited_at)
    )
    message.save!
    chat.update!(last_activity_at: sent_at) if chat.last_activity_at.nil? || sent_at > chat.last_activity_at
    message
  end

  # An edit replaces the content of a message we hold, unless it is deleted
  # or a newer edit is already applied. An edit for a message we don't hold
  # yet leaves a placeholder with the edited content, so the original's
  # later (older) delivery cannot put the superseded text back.
  def apply_edit!(connection, attributes)
    attributes = attributes.slice(*EDIT_FIELDS)
    edited_at = time(attributes["edited_at"]) || raise(Refused.new(:bad_edit, :unprocessable_entity))
    chat = connection.comms_chats.find_or_create_by!(provider_chat_id: attributes["chat"].to_s)
    message = chat.comms_messages.find_or_initialize_by(provider_message_id: attributes["provider_message_id"].to_s)
    if message.new_record?
      message.update!(service_connection: connection, sent_at: edited_at, placeholder: true,
                      body: attributes["body"], caption: attributes["caption"],
                      edited_at:, edit_version: version_of(edited_at))
      return
    end
    return if message.deleted?

    apply_content!(message, attributes, edited_at)
  end

  def apply_content!(message, attributes, edited_at)
    return unless edited_at

    version = version_of(edited_at)
    return if message.edit_version && message.edit_version >= version

    message.update!(body: attributes["body"], caption: attributes["caption"], edited_at:, edit_version: version)
  end

  def fill_placeholder!(message, attributes, sent_at)
    message.update!(
      placeholder: false, sent_at: sent_at,
      sender_id: attributes["sender_id"], sender_name: attributes["sender_name"],
      media_kind: attributes["media_kind"]
    )
  end

  def version_of(time)
    (time.to_r * 1_000_000).to_i
  end

  # Deletions name their chat (the connector resolves Telegram's peerless
  # deletes from its own durable map, or counts them as unresolved). A
  # deletion for a message we don't hold yet leaves a tombstone, so a backfill
  # or a late delivery can never bring it back.
  def apply_deletion!(connection, deletion, now)
    ids = deletion["provider_message_ids"]
    raise Refused.new(:bad_deletion, :unprocessable_entity) unless ids.is_a?(Array) && ids.size <= MAX_BATCH
    deleted_at = time(deletion["deleted_at"]) || now

    chat = connection.comms_chats.find_or_create_by!(provider_chat_id: deletion["chat"].to_s)
    ids.map(&:to_s).uniq.each do |id|
      message = chat.comms_messages.find_or_initialize_by(provider_message_id: id)
      if message.persisted?
        message.tombstone!(at: deleted_at)
      else
        message.update!(service_connection: connection, sent_at: deleted_at, deleted_at:, placeholder: true)
      end
    end
  end

  def record_unresolved_deletions!(connection, count)
    state = connection.connector_state.to_h
    connection.update!(connector_state: state.merge("deletions_not_applied" => state["deletions_not_applied"].to_i + count))
  end

  def time(value)
    return value if value.is_a?(Time)

    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

end
