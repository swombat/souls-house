# What the stalled-thread sweeper sees of a quiet room at one moment, `at`.
#
# The same builder serves the sweeper job (at = now, live receipts) and the
# offline dataset (at = a hypothetical sweep time inside a historical gap), so
# what the classifier is tuned on is exactly what it will be shown. Nothing
# created after `at` is read. State that has no history (whether a resident
# was paused then) is "unknown" in a historical snapshot, never today's value.
#
# Shown: the last RUNS speaker-runs (consecutive messages by one author are one
# run), the last human message if it falls before them, and receipts the text
# cannot carry: time since the last message, who in the room had a run going,
# what became of resident-to-resident handoffs, and follow-through nudges
# since the last human message. Truncation is said, not hidden.
class StalledThreadSnapshot

  RUNS = 3
  MESSAGE_LIMIT = 12
  MESSAGE_CHARS = 1_500
  TOTAL_CHARS = 14_000

  attr_reader :chat, :at

  def initialize(chat, at:, live: false)
    @chat = chat
    @at = at
    @live = live
  end

  def live?
    @live
  end

  def messages_scope
    chat.messages.kept.where(role: %w[user assistant], progress_message: false).where("messages.created_at <= ?", at)
  end

  def last_message
    @last_message ||= messages_scope.reorder(created_at: :desc, id: :desc).first
  end

  def last_human_message
    @last_human_message ||= messages_scope.where.not(user_id: nil).where(agent_id: nil)
      .reorder(created_at: :desc, id: :desc).first
  end

  # The last RUNS speaker-runs, oldest first, capped at MESSAGE_LIMIT messages.
  def window
    @window ||= begin
      recent = messages_scope.includes(:agent, :user).reorder(created_at: :desc, id: :desc).limit(MESSAGE_LIMIT * 2).to_a
      runs = 0
      previous = nil
      picked = []
      recent.each do |message|
        key = speaker_key(message)
        if key != previous
          runs += 1
          break if runs > RUNS
          previous = key
        end
        picked << message
        break if picked.size >= MESSAGE_LIMIT
      end
      picked.reverse
    end
  end

  def state
    return if last_message.nil?

    shown = window
    budget = TOTAL_CHARS
    truncated = shown.size >= MESSAGE_LIMIT
    described = shown.reverse.map do |message|
      limit = [ MESSAGE_CHARS, [ budget, 200 ].max ].min
      truncated ||= message.content.to_s.length > limit
      budget -= [ message.content.to_s.length, limit ].min
      describe(message, limit)
    end.reverse

    human = last_human_message
    last_resident = shown.reverse.find { |m| m.agent_id.present? }
    state = {
      now: at.iso8601,
      minutes_since_last_message: ((at - last_message.created_at) / 60).floor,
      residents_in_room: residents,
      recent_messages: described,
      recent_messages_truncated: truncated,
      last_human_message_after_last_resident_message: human.present? && (last_resident.nil? || human.id > last_resident.id),
      follow_through_nudges_since_last_human_message: nudges_since(human)
    }
    if human && shown.none? { |m| m.id == human.id }
      state[:last_human_message_before_window] = describe(human, MESSAGE_CHARS)
    end
    state[:last_human_message_at] = human&.created_at&.iso8601
    state
  end

  private

  def speaker_key(message)
    return "agent:#{message.agent_id}" if message.agent_id
    return "user:#{message.user_id}" if message.user_id

    "system"
  end

  def author_kind(message)
    return "resident" if message.agent_id
    return "person" if message.user_id

    "system"
  end

  def describe(message, limit)
    {
      id: message.obfuscated_id,
      author: message.agent&.name || message.user&.full_name || "system",
      author_kind: author_kind(message),
      at: message.created_at.iso8601,
      content: message.content.to_s.truncate(limit),
      handoffs: handoffs_for(message)
    }.compact
  end

  # What became of a resident's request to another resident, as of `at`.
  # Status history isn't stored: delivered_at is, and a blocked row that
  # hasn't changed since before `at` was blocked then. Anything else is
  # "requested" (queued or held; which one is not recoverable afterwards).
  def handoffs_for(message)
    return unless message.agent_id

    rows = MessageHandoff.where(message_id: message.id).where("created_at <= ?", at).includes(:recipient_agent).to_a
    return if rows.empty?

    rows.map do |row|
      state =
        if live?
          row.status
        elsif row.delivered_at && row.delivered_at <= at
          "delivered"
        elsif row.status == "blocked" && row.updated_at <= at
          "blocked"
        else
          "requested"
        end
      { to: row.recipient_agent&.name, state: state, reason: (row.reason if state == "blocked") }.compact
    end
  end

  def residents
    chat.agents.map do |agent|
      {
        name: agent.name,
        paused: live? ? agent.paused? : "unknown",
        run_in_progress: run_in_progress?(agent)
      }
    end
  end

  def run_in_progress?(agent)
    runs = chat.agent_runtime_interactions.where(agent: agent)
    return runs.order(:id).last(5).any?(&:active?) if live?

    runs.where("started_at <= ?", at).where("finished_at IS NULL OR finished_at > ?", at)
      .where("started_at > ?", at - 2.hours).exists?
  end

  def nudges_since(human)
    scope = chat.agent_runtime_interactions.where.not(follow_through_of_id: nil).where("created_at <= ?", at)
    scope = scope.where("created_at > ?", human.created_at) if human
    scope.count
  end

end
