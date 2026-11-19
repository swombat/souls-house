# Actions over many conversations at once, for the sidebar's Actions menu and
# the bulk API (Daniel, JWboWj): one request, rather than one round trip per
# conversation. Marking read is a fixed handful of queries however many; the
# tag is one UPDATE, plus each changed room's own transcript line.
#
# Callers pass a relation already narrowed to what the person may touch (an
# account's kept conversations); the public IDs only pick from inside it, so a
# foreign or deleted ID is skipped, never acted on.
class ConversationBulk

  MAX_CONVERSATIONS = 500

  class InvalidIds < ArgumentError; end

  # Public conversation IDs → database IDs. Strict like VisualTag.resolve_for:
  # letters only and a clean round trip, so "12" or a stray integer can't
  # address a row by its raw ID.
  def self.decode_ids(public_ids, max: MAX_CONVERSATIONS)
    unless public_ids.is_a?(Array) && public_ids.any? && public_ids.size <= max
      raise InvalidIds, "conversation_ids must be a list of 1 to #{max} conversation IDs"
    end

    public_ids.map do |public_id|
      id = public_id.is_a?(String) && public_id.match?(/\A[a-zA-Z]+\z/) ? Chat.decode_id(public_id) : nil
      raise InvalidIds, "#{public_id.to_s.truncate(40)} is not a conversation ID" unless id && Chat.encode_id(id) == public_id

      id
    end
  end

  # {public conversation ID => public message ID} → {chat_id => message_id},
  # every message a kept one in the conversation it is paired with. A pair
  # that doesn't hold is refused as a whole, like a malformed ID.
  def self.decode_cutoffs(pairs, max: MAX_CONVERSATIONS)
    unless pairs.respond_to?(:to_h) && (pairs = pairs.to_h).any? && pairs.size <= max
      raise InvalidIds, "through_message_ids must map 1 to #{max} conversation IDs to message IDs"
    end

    chat_ids = decode_ids(pairs.keys, max: max)
    message_ids = pairs.values.map do |public_id|
      id = public_id.is_a?(String) && public_id.match?(/\A[a-zA-Z]+\z/) ? Message.decode_id(public_id) : nil
      raise InvalidIds, "#{public_id.to_s.truncate(40)} is not a message ID" unless id && Message.encode_id(id) == public_id

      id
    end
    cutoffs = chat_ids.zip(message_ids).to_h
    found = Message.kept.where(id: message_ids).pluck(:id, :chat_id).to_h
    unless cutoffs.all? { |chat_id, message_id| found[message_id] == chat_id }
      raise InvalidIds, "Each message must belong to the conversation it is paired with"
    end

    cutoffs
  end

  # Clears the person's red eyes in these conversations, as a single
  # ReplyDismissal.dismiss! does for one. With `cutoffs` ({chat_id =>
  # message_id}, what the list was showing) each conversation is dismissed
  # through that message only, so one that arrived after the person looked
  # still raises its eye. Without, through each conversation's latest message
  # at the moment this runs (the API's conversation_ids form).
  # The chat rows are locked in one ordered SELECT … FOR UPDATE, which is the
  # lock classification takes (ReplyExpectation.record!), so a flag landing
  # mid-action either sees the new cutoff or is closed by the UPDATE below.
  # A fixed number of queries however many conversations. Returns the public
  # IDs acted on.
  def self.mark_read!(chats:, user:, cutoffs: nil)
    acted = []
    Chat.transaction do
      scope = cutoffs ? chats.where(id: cutoffs.keys) : chats
      ids = locked(scope).pluck(:id)
      through = cutoffs ? cutoffs.slice(*ids) : Message.kept.where(chat_id: ids).group(:chat_id).maximum(:id)
      if through.any?
        now = Time.current
        ReplyDismissal.upsert_all(
          through.map { |chat_id, message_id| { chat_id: chat_id, user_id: user.id, through_message_id: message_id, created_at: now, updated_at: now } },
          unique_by: %i[chat_id user_id],
          on_duplicate: Arel.sql(
            "through_message_id = GREATEST(reply_dismissals.through_message_id, EXCLUDED.through_message_id), " \
            "updated_at = EXCLUDED.updated_at"
          )
        )
        ReplyExpectation.state_open.where(user_id: user.id)
          .where(message_id: Message.joins("JOIN reply_dismissals ON reply_dismissals.chat_id = messages.chat_id")
            .where(reply_dismissals: { user_id: user.id, chat_id: through.keys })
            .where("messages.id <= reply_dismissals.through_message_id").select(:id))
          .update_all(state: ReplyExpectation.states.fetch("dismissed"), updated_at: now)
      end
      acted = through.keys
    end
    # One refresh for the person's eyes, instead of one per closed flag.
    ReplyExpectation.refresh_for(user.id)
    acted.sort.map { |id| Chat.encode_id(id) }
  end

  # Sets (or, with nil, clears) the tag on every conversation: the tag itself
  # in one UPDATE, then one transcript line per conversation whose tag
  # changed, written the ordinary way (Message.create!, with its revision and
  # notifications), so that part grows with the number changed.
  # Archived conversations hold no tag (Chat::Archivable) and are left alone.
  # Each conversation whose tag actually changed still gets its own line
  # ("Daniel changed the tag to Building"), because that line is the room's
  # record for everyone in it, not the actor's. Returns the public IDs changed.
  def self.set_tag!(chats:, tag:, by:)
    changed = []
    Chat.transaction do
      rows = locked(chats.where(archived_at: nil)).includes(:visual_tag).to_a
      if tag && rows.any? { |chat| chat.account_id != tag.account_id }
        raise ArgumentError, "The tag belongs to another account"
      end
      targets = rows.reject { |chat| chat.visual_tag_id == tag&.id }
      if targets.any?
        Chat.where(id: targets.map(&:id)).update_all(visual_tag_id: tag&.id, updated_at: Time.current)
        targets.each do |chat|
          ConversationTagEvent.changed!(chat: chat, from: chat.visual_tag, to: tag, by: by)
        end
      end
      changed = targets
    end
    # update_all skips the per-row callbacks, so do once what each would have
    # done: refresh the account's list, and the eyes of everyone flagged in
    # these rooms (a tag can hide a room from the badge totals; Chat).
    if changed.any?
      account = changed.first.account
      ActionCable.server.broadcast("Account:#{account.obfuscated_id}", { action: "refresh" })
      ReplyExpectation.joins(:message).where(messages: { chat_id: changed.map(&:id) }).distinct.pluck(:user_id)
        .each { |user_id| ReplyExpectation.refresh_for(user_id) }
    end
    changed.map(&:to_param)
  end

  # The rows in id order, locked. The filter may join (the Hidden filter's
  # LEFT JOIN on visual_tags), and Postgres refuses FOR UPDATE on the nullable
  # side of an outer join, so the lock goes on a plain query by id.
  def self.locked(chats)
    Chat.where(id: chats.select(:id)).order(:id).lock
  end
  private_class_method :locked

end
