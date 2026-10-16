# What the stalled-thread sweeper shows Jev about one conversation: the
# last few speaker-runs, the latest human request if it has scrolled out of
# that window, and receipts the text cannot carry (how long the room has
# been quiet, who is paused, which runs started, what the handoff receipts
# say). Built from the same code for a live judgement and for a historical
# snapshot (as_of an earlier message), so the training set and the live
# input have the same shape.
#
# A snapshot as_of an earlier message sees nothing after that message. Two
# receipts cannot be rewound: a resident's paused flag and a message's
# handoff receipts are read as they are now. The dataset labels them
# `current_state` so a reader knows.
class StalledThreadSnapshot

  SPEAKER_RUNS = 3
  MESSAGE_LIMIT = 12
  MESSAGE_CHARS = 1_500
  # Handovers sit at the end of long messages ("merge stays with you"), so
  # a long message keeps its head and its tail, and loses the middle.
  TAIL_CHARS = 500
  HUMAN_REQUEST_CHARS = 1_500
  RECEIPT_LIMIT = 10

  attr_reader :chat, :as_of, :now

  def initialize(chat, as_of: nil, now: nil)
    @chat = chat
    @as_of = as_of || visible_messages.last
    @now = now || Time.current
  end

  # Human and resident messages, no progress rows, no streaming rows, up to as_of.
  def visible_messages
    scope = chat.messages.kept.where(role: %w[user assistant], progress_message: false, streaming: false).reorder(:id)
    scope = scope.where("messages.id <= ?", as_of.id) if defined?(@as_of) && @as_of
    scope
  end

  # The last SPEAKER_RUNS runs of consecutive messages by one author, newest
  # last, capped at MESSAGE_LIMIT messages.
  def window
    @window ||= begin
      picked = []
      runs = 0
      previous_key = nil
      visible_messages.reorder(id: :desc).limit(MESSAGE_LIMIT * 2).each do |message|
        key = author_key(message)
        runs += 1 if key != previous_key
        break if runs > SPEAKER_RUNS || picked.size >= MESSAGE_LIMIT
        picked << message
        previous_key = key
      end
      picked.reverse
    end
  end

  def last_human_message
    @last_human_message ||= visible_messages.where.not(user_id: nil).reorder(id: :desc).first
  end

  def last_resident_message
    @last_resident_message ||= visible_messages.where(role: "assistant").where.not(agent_id: nil).reorder(id: :desc).first
  end

  def state
    first = window.first
    last = window.last
    human_in_window = last_human_message && window.any? { |m| m.id == last_human_message.id }
    {
      now: now.iso8601,
      conversation: { id: chat.to_param, title: chat.title.to_s.truncate(120) },
      residents_in_room: chat.agents.map do |agent|
        { id: "agent:#{agent.id}", name: agent.name, paused: agent.paused?, current_state: true }
      end,
      quiet_for_minutes: last ? ((now - last.created_at) / 60).floor : nil,
      last_message: last && { id: last.obfuscated_id, author: author_name(last), kind: author_kind(last) },
      # Who spoke last, and who has not spoken since: the shape of a handover.
      latest_by_participant: latest_by_participant,
      last_human_after_last_resident: last_human_message && last_resident_message ? last_human_message.id > last_resident_message.id : last_human_message.present?,
      window: window.map { |m| describe(m, MESSAGE_CHARS) },
      window_truncated: first ? visible_messages.where("messages.id < ?", first.id).exists? : false,
      earlier_human_request: (last_human_message && !human_in_window) ? describe(last_human_message, HUMAN_REQUEST_CHARS) : nil,
      receipts: {
        resident_runs_since_window_start: first ? runs_since(first.created_at) : [],
        sweeper_wakes_since_last_human: 0
      }
    }
  end

  private

  # For each resident in the room and for the latest human: their last
  # message id and time, and whether anyone else has spoken since it.
  def latest_by_participant
    last = window.last
    entries = chat.agents.map do |agent|
      message = visible_messages.where(agent_id: agent.id).reorder(id: :desc).first
      {
        participant: agent.name, kind: "resident",
        last_message_id: message&.obfuscated_id, at: message&.created_at&.iso8601,
        others_spoke_since: message ? (last && last.id > message.id) : nil,
        in_window: message ? window.any? { |m| m.id == message.id } : false
      }
    end
    if last_human_message
      entries << {
        participant: author_name(last_human_message), kind: "human",
        last_message_id: last_human_message.obfuscated_id, at: last_human_message.created_at.iso8601,
        others_spoke_since: last && last.id > last_human_message.id, in_window: window.any? { |m| m.id == last_human_message.id }
      }
    end
    entries
  end

  def author_key(message)
    if message.agent_id then "agent:#{message.agent_id}"
    elsif message.user_id then "user:#{message.user_id}"
    else "system"
    end
  end

  def author_kind(message)
    if message.agent_id then "resident"
    elsif message.user_id then "human"
    else "platform"
    end
  end

  def author_name(message)
    message.agent&.name || message.user&.full_name || "souls.house (platform)"
  end

  def describe(message, limit)
    hash = {
      id: message.obfuscated_id,
      author: author_name(message),
      kind: author_kind(message),
      at: message.created_at.iso8601,
      content: clip(message.content.to_s, limit)
    }
    receipts = message.role == "assistant" ? Array(message.handoff_receipts) : []
    if receipts.any?
      hash[:handoffs] = receipts.map { |r| r.respond_to?(:slice) ? r.slice("recipient", "recipient_name", "name", "status", "reason") : r }
      hash[:handoffs_current_state] = true
    end
    hash
  end

  def clip(text, limit)
    return text if text.length <= limit
    head = limit - TAIL_CHARS - 7
    "#{text[0, head]} [...] #{text[-TAIL_CHARS..]}"
  end

  # Who was run in this room from the window's start up to as_of: credential-safe.
  def runs_since(since)
    scope = chat.agent_runtime_interactions.includes(:agent).where(trigger_kind: "conversation").where("started_at >= ?", since)
    scope = scope.where("started_at <= ?", as_of.created_at + 1.second) if as_of
    scope.order(:started_at).limit(RECEIPT_LIMIT).map do |run|
      {
        resident: run.agent&.name, started_at: run.started_at&.iso8601, finished_at: run.finished_at&.iso8601,
        active: run.active?, outcome: run.execution_state.presence || run.runtime_status.presence,
        follow_through_nudge: run.follow_through_of_id.present?
      }
    end
  end

end
