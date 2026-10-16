# What the stalled-thread sweeper sees of a quiet room at one moment, `at`.
#
# The same builder serves the sweeper job (at = now, live receipts) and the
# offline dataset (at = a hypothetical sweep time inside a historical gap), so
# what the classifier is tuned on is exactly what it will be shown. Nothing
# created after `at` is read; a message discarded after `at` is still shown,
# one discarded before it is not; a resident who joined after `at` is left
# out. State that has no history is never filled in from today: pause state
# is "unknown", and so is a run the records never saw finish.
#
# Some things cannot be rewound at all. Message text has no edit history, so a
# message updated after `at` (an edit, the end of a stream, a moderation pass)
# may show later text than the room showed then; departures from the room
# leave no row. A historical snapshot lists these in #provenance, outside the
# state Jev sees, so a dataset can report or exclude them rather than claim
# strict as-of equivalence.
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
  # Message text in recent_messages never exceeds TOTAL_CHARS (older messages
  # are dropped, and truncation flagged, before any falls under
  # MIN_MESSAGE_CHARS). An earlier human message outside the window adds at
  # most MESSAGE_CHARS more.
  TOTAL_CHARS = 14_000
  MIN_MESSAGE_CHARS = 200

  SWEEP_OFFSETS = [ 60.minutes, 30.minutes, 10.minutes ].freeze

  # Where in a historical gap the dataset puts its sweep: the largest offset
  # strictly inside the gap, so the message that ended the gap is never in
  # the snapshot. nil when none fits.
  def self.sweep_offset(gap)
    SWEEP_OFFSETS.find { |offset| offset < gap }
  end

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
    scope = chat.messages.where(role: %w[user assistant], progress_message: false).where("messages.created_at <= ?", at)
    live? ? scope.kept : scope.where("messages.discarded_at IS NULL OR messages.discarded_at > ?", at)
  end

  # What a historical snapshot could not reconstruct. Not shown to Jev.
  def provenance
    return { as_of: "live" } if live?

    shown = window + [ last_human_message ].compact
    {
      as_of: "historical",
      content_unverified_ids: shown.select { |m| m.updated_at > at }.map(&:obfuscated_id).uniq,
      membership: "current_minus_later_joins",
      run_state_unknown: residents.any? { |r| r[:run_in_progress] == "unknown" }
    }
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
    described = []
    # Newest first, so the budget runs out on the oldest messages.
    shown.reverse_each do |message|
      limit = [ MESSAGE_CHARS, budget ].min
      if limit < MIN_MESSAGE_CHARS
        truncated = true
        break
      end
      truncated ||= message.content.to_s.length > limit
      budget -= [ message.content.to_s.length, limit ].min
      described.unshift(describe(message, limit))
    end
    shown = shown.last(described.size)

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
    @residents ||= members.map do |agent|
      {
        name: agent.name,
        paused: live? ? agent.paused? : "unknown",
        run_in_progress: run_in_progress?(agent)
      }
    end
  end

  # In seating order, the same for live and historical snapshots, so the
  # classifier's positional question keys line up.
  def members
    seated = chat.agents.reorder("chat_agents.id")
    seated = seated.where("chat_agents.created_at <= ?", at) unless live?
    seated.to_a
  end

  # true, false, or "unknown" when a run that had started by `at` has no
  # recorded finish and isn't running now: it ended unrecorded, and when is
  # not known.
  def run_in_progress?(agent)
    runs = chat.agent_runtime_interactions.where(agent: agent)
    return runs.order(:id).last(5).any?(&:active?) if live?

    started = runs.where("started_at <= ?", at)
    return true if started.where("finished_at > ?", at).exists?

    unfinished = started.where(finished_at: nil).to_a
    return true if unfinished.any?(&:active?)
    return "unknown" if unfinished.any?

    false
  end

  def nudges_since(human)
    scope = chat.agent_runtime_interactions.where.not(follow_through_of_id: nil).where("created_at <= ?", at)
    scope = scope.where("created_at > ?", human.created_at) if human
    scope.count
  end

end
