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
# - only kept, finished person and resident messages (no working progress).
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
class Rhythm::QuietGate

  SETTLE = 5.minutes

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
    first_unsettled = unsettled.minimum(:id)
    first_unsettled ? first_unsettled - 1 : (Message.maximum(:id) || 0)
  end

  def countable_messages
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
