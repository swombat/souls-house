# The quiet gate (#951): a rhythm that only runs when something has happened
# since it last did. The check is a database query made before any room,
# dispatch or model wake, so a quiet slot costs nothing.
#
# What counts as something happening is the load-bearing part:
# - only conversations of the rhythm's account that EVERY seated resident can
#   read (is a member of), so activity in a room one of them cannot see never
#   changes whether the group wakes, and never leaks that it happened;
# - optionally narrowed to named rooms; the membership rule still applies;
# - never the rhythm's own occurrence conversations, or each run's own output
#   would wake the next;
# - never messages written by the seated residents themselves;
# - only kept, completed person and resident messages, by the same rule as
#   the API's completed flag: not streaming, and a person's message or a
#   resident's with content or an attachment. Working progress, blank and
#   still-streaming rows never count until they complete.
#
# The watermark is a message id, and ids follow insert order, not commit
# order. The bound, stated plainly: a message whose inserting transaction
# stays open longer than SETTLE can commit below a watermark taken meanwhile
# and be missed by the gate (the resident still sees it on its next run, or
# on any later wake). Within that bound nothing is missed: the watermark stops
# just below the oldest message that had not yet settled, so a lower-id
# message stamped late, and everything posted while an occurrence runs, sit
# above it and are counted at the next check. The cost of the margin is at
# most one extra wake for a message that arrived just before a run.
#
# An unfinished resident message is the other late arrival: its row is
# inserted blank or streaming and completes later by update, so its id can be
# old by the time it becomes news. The watermark also stops just below the oldest
# unfinished countable message younger than UNFINISHED_HOLD, so when it
# completes it is still above the watermark and counts. A row left unfinished
# for longer than that is treated as abandoned and stops holding the watermark;
# if it completes after that, the gate can miss it (the same kind of bound).
class Rhythm::QuietGate

  SETTLE = 5.minutes
  UNFINISHED_HOLD = 2.hours

  # The API's completion rule (Chat::Summarizable: not streaming, and
  # Message#completed?) in SQL: not streaming, and a person's message or a
  # resident's with non-blank content or at least one attachment. NULL-safe,
  # so NOT of it is exactly the unfinished rows.
  COMPLETED_SQL = <<~SQL.squish.freeze
    (messages.streaming = FALSE) AND (messages.role = 'user' OR (messages.role = 'assistant' AND (
      COALESCE(messages.content, '') ~ '[^[:space:]]' OR EXISTS (
        SELECT 1 FROM active_storage_attachments asa
        WHERE asa.record_type = 'Message' AND asa.record_id = messages.id AND asa.name = 'attachments'))))
  SQL

  def initialize(rhythm)
    @rhythm = rhythm
  end

  # True when a countable message has arrived above the watermark.
  def news_after?(watermark_id)
    countable_messages.where("messages.id > ?", watermark_id).exists?
  end

  # The next watermark: just below the oldest message newer than SETTLE, or
  # the newest message when every one has settled. Scanning only above the
  # previous watermark keeps the query to the messages since the last check.
  def settled_watermark(now = Time.current, after: @rhythm.quiet_watermark_message_id)
    unsettled = Message.where(created_at: (now - SETTLE)..)
    unsettled = unsettled.where("messages.id > ?", after) if after
    unfinished = candidate_messages.where.not(COMPLETED_SQL).where(created_at: (now - UNFINISHED_HOLD)..)
    unfinished = unfinished.where("messages.id > ?", after) if after
    first_unsettled = [ unsettled.minimum(:id), unfinished.minimum(:id) ].compact.min
    first_unsettled ? first_unsettled - 1 : (Message.maximum(:id) || 0)
  end

  def countable_messages
    candidate_messages.where(COMPLETED_SQL)
  end

  private

  def candidate_messages
    seated = @rhythm.agents.reload.ids
    return Message.none if seated.empty?

    readable_by_all = ChatAgent.where(agent_id: seated).group(:chat_id)
      .having("COUNT(DISTINCT chat_agents.agent_id) = ?", seated.size).select(:chat_id)
    chats = @rhythm.account.chats.kept.where(id: readable_by_all)
      .where.not(id: RhythmOccurrence.where(rhythm_id: @rhythm.id).select(:chat_id))
    chats = chats.where(room_id: @rhythm.quiet_gate_room_ids) if @rhythm.quiet_gate_room_ids.present?

    Message.where(chat_id: chats.select(:id), role: %w[user assistant], discarded_at: nil, progress_message: false)
      .where("messages.agent_id IS NULL OR messages.agent_id NOT IN (?)", seated)
  end

end
