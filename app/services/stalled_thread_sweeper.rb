# Finds quiet rooms and judges each once per state with StalledThreadClassifier.
#
# Shadow mode (slice 2 of BjZQAe): every verdict becomes a StalledThreadSweep
# row an admin can read; nothing is posted and nobody is woken. The row is
# keyed on (chat, last message), so a room is judged again only after
# something new is said in it.
#
# A room is a candidate when it is active and respondable, has residents, its
# account is enabled, its last message is older than the setting's interval
# but newer than LOOKBACK (so switching the sweeper on doesn't judge every
# room ever left quiet), no resident has a run going in it, and that state
# has no verdict yet.
class StalledThreadSweeper

  INTERVALS = [ 0, 10, 30, 60 ].freeze
  LOOKBACK = 3.days
  PER_TICK = 20
  PROMPT_VERSION = "v3".freeze

  def self.interval
    minutes = Setting.instance.stalled_sweep_minutes.to_i
    minutes.positive? ? minutes.minutes : nil
  end

  def self.enabled?
    interval.present?
  end

  def initialize(now: Time.current, interval: self.class.interval, decide: UtilityInference.method(:decide))
    @now = now
    @interval = interval
    @decide = decide
  end

  def call
    return [] unless @interval

    candidates.first(PER_TICK).filter_map { |chat, message| judge(chat, message) }
  end

  # [chat, last message] pairs, oldest quiet first.
  def candidates
    last_ids = Message.where(role: %w[user assistant], progress_message: false).kept
      .where(created_at: (@now - LOOKBACK)..)
      .group(:chat_id).maximum(:id)
    return [] if last_ids.empty?

    messages = Message.where(id: last_ids.values).where("created_at <= ?", @now - @interval).index_by(&:chat_id)
    judged = StalledThreadSweep.where(message_id: messages.values.map(&:id)).pluck(:message_id).to_set
    chats = Chat.kept.active.where(id: messages.keys).includes(:account, :agents)
    chats.filter_map do |chat|
      message = messages[chat.id]
      next if judged.include?(message.id)
      next unless chat.respondable? && !chat.account.disabled? && chat.agents.any?

      [ chat, message ]
    end.sort_by { |_, message| message.created_at }
  end

  def judge(chat, message)
    # A run going (or queued) in the room: it isn't stalled, it's working.
    # No row, so the next tick looks again once it has settled.
    return if chat.agents.any? { |agent| chat.agent_response_active?(agent) }

    snapshot = StalledThreadSnapshot.new(chat, at: @now, live: true)
    return if snapshot.last_message&.id != message.id

    state = snapshot.state
    return if state[:residents_in_room].any? { |r| r[:run_in_progress] == true }

    verdict = StalledThreadClassifier.call(state, decide: @decide)
    record(chat, message, state, verdict)
  rescue UtilityInference::InputTooLong, UtilityInference::InvalidResponse => error
    record_error(chat, message, error)
  end

  private

  def record(chat, message, state, verdict)
    residents = chat.agents.reorder("chat_agents.id").to_a
    scores = verdict.wake.each_with_index.map do |(resident, score), index|
      { agent_id: residents[index]&.to_param, name: resident[:name], score: score }
    end
    would_wake = verdict.wake_residents.map { |resident| resident[:name] }
    outcome = if would_wake.any? then "would_wake" elsif verdict.person_holds? then "person_holds" else "quiet" end
    StalledThreadSweep.create!(
      account: chat.account, chat: chat, message: message, outcome: outcome,
      scores: scores, person_holds: verdict.person_holds, would_wake: would_wake,
      quiet_minutes: state[:minutes_since_last_message], prompt_version: PROMPT_VERSION
    )
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def record_error(chat, message, error)
    StalledThreadSweep.create!(
      account: chat.account, chat: chat, message: message, outcome: "error",
      error_class: error.class.name, prompt_version: PROMPT_VERSION
    )
  rescue ActiveRecord::RecordNotUnique
    nil
  end

end
