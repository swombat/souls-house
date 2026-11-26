# A resident's one-shot promise to come back to something at a given time
# (#699 slice B; Daniel in YNwRqe eGXwAY/JyOLLe). "I'll check the deploy at
# 03:00" becomes a row; CommitmentSweepJob looks every minute for rows that
# are due, with no model call, and activates each once:
#
# - a house message, "Commitment due", carrying the commitment's headline
#   (the resident's short summary, or one cut from the text), the time it
#   was due and the time it was delivered, and where it was made, posted in
#   the conversation it was made in (the default) or in a new conversation
#   in a chosen room of the same account. The full text is not repeated
#   there (Daniel, JVvqyJ: a notice, not the brief); the resident's run gets
#   it in its cue, and people see it on the resident's page;
# - a wake for the resident, the same path a knock takes: woken now, or held
#   as a PendingWake if the resident is already responding there.
#
# The house keeps custody of that wake until it is delivered. Every run it
# starts carries the commitment as its own cue in the request
# (ExternalAgentResponseRequest#commitment_cue_text), so delivery does not
# depend on the message surviving a bounded transcript window: delivered
# means the run carrying the cue ended ok. Each sweep brings activated rows up
# to date (sync_wake!). A held wake that is released is followed to its run;
# one that is dropped (expired, refused at claim), a reservation refused for
# now, or a run cancelled or refused before it started go back to retrying,
# which wakes again once nothing stands in the way (paused, out of the room
# and so on wait, with the reason). A run that started and ended any other
# way may have acted, so it is not replayed: the row says blocked and why.
# The message is never posted twice, and at most MAX_WAKE_RUNS runs are
# started for one commitment.
#
# One occurrence per row. A commitment may recur (Daniel, eRNlOe YrBKBw):
# every N minutes, or a random pick between recur_min_minutes and
# recur_max_minutes. It is the goal-shaped promise, "keep waking me until
# this is done", not a timetable (that is a Rhythm). When a recurring row
# activates, the same lock schedules its successor (schedule_next!) from the
# moment of activation, so a series has at most one scheduled row and a
# pause or an outage makes it late, never a backlog. Cancelling any row of a
# series ends the series (end_series!): that is how a resident says the
# goal is met. Several commitments may be scheduled at once, but not two
# with the same text for the same resident: the text is the commitment's
# identity, compared after trimming, collapsing whitespace and ignoring
# case, among scheduled rows only, so an activated or cancelled commitment
# (including a series' own earlier occurrences) never blocks a new promise.
#
# A due commitment that cannot be delivered yet (the resident is paused,
# held for billing, out of the room; the conversation is archived; live
# activity is off) posts nothing. The row stays scheduled with the reason
# and the time it was tried, and the next sweep tries again, so an outage or
# a pause makes it late, never skipped. The row lock and the status check
# make a repeated sweep a no-op: one message, one conversation, one wake.
#
# Residents create and manage their own commitments (API: resident keys).
# People see them on the resident's page, beside reflexes, and whoever can
# manage the resident may cancel or reschedule; there is no human "create".
class Commitment < ApplicationRecord

  include ObfuscatesId

  STATUSES = %w[scheduled activated cancelled].freeze
  DESTINATIONS = %w[same_conversation new_conversation].freeze
  TEXT_LENGTH = 20_000
  TITLE_LENGTH = 80
  # "Five to ten words" (Daniel, JVvqyJ). Characters, not words, are what
  # the house can hold a resident to; 100 leaves room for ten long ones.
  SUMMARY_LENGTH = 100
  HEADLINE_WORDS = 12
  WAKE_STATES = %w[woken held retrying delivered blocked withdrawn].freeze
  IN_CUSTODY = %w[woken held retrying].freeze
  MAX_WAKE_RUNS = 5
  # A floor so a series cannot become a loop, and a ceiling past which a
  # Rhythm is the better tool.
  RECUR_MIN_MINUTES = 5
  RECUR_MAX_MINUTES = 30 * 24 * 60
  RECUR_MAX_OCCURRENCES = 1000

  Result = Struct.new(:status, :reason, keyword_init: true) do
    def activated? = status == :activated
  end

  belongs_to :account
  belongs_to :agent
  belongs_to :source_chat, class_name: "Chat"
  belongs_to :source_message, class_name: "Message", optional: true
  belongs_to :room, optional: true
  belongs_to :activation_chat, class_name: "Chat", optional: true
  belongs_to :activation_message, class_name: "Message", optional: true
  belongs_to :cancelled_by_user, class_name: "User", optional: true
  belongs_to :cancelled_by_agent, class_name: "Agent", optional: true
  belongs_to :wake_interaction, class_name: "AgentRuntimeInteraction", optional: true
  belongs_to :pending_wake, optional: true
  belongs_to :pending_wake_source, optional: true
  belongs_to :series_root, class_name: "Commitment", optional: true
  belongs_to :previous_commitment, class_name: "Commitment", optional: true
  has_one :next_commitment, class_name: "Commitment", foreign_key: :previous_commitment_id, inverse_of: :previous_commitment

  validates :status, inclusion: { in: STATUSES }
  validates :destination, inclusion: { in: DESTINATIONS }
  validates :text, presence: true, length: { maximum: TEXT_LENGTH }
  validates :summary, length: { maximum: SUMMARY_LENGTH }
  validates :due_at, presence: true
  validate :due_in_future, if: -> { scheduled? && will_save_change_to_due_at? }
  validate :resident_in_source, on: :create
  validate :source_message_in_source, on: :create
  validate :room_valid
  # A commitment made in a private conversation wakes there and nowhere else
  # (eKmnrJ): its words must not reach a wider room.
  validate :private_source_stays_home
  validate :text_unique_while_scheduled, if: -> { scheduled? && (new_record? || will_save_change_to_text?) }
  validate :recurrence_valid

  before_validation :set_account, on: :create
  before_validation :set_text_digest
  before_validation :normalise_summary
  # Also on save, so the unique index sees a digest even when validation is
  # skipped.
  before_save :set_account, :set_text_digest
  # The sidebar marks a conversation with a commitment waiting in it
  # (Chat.waiting_commitments_for); making, moving, cancelling or
  # delivering one changes that mark without touching the chat.
  after_commit :refresh_sidebar_mark, if: :sidebar_mark_changed?

  scope :scheduled, -> { where(status: "scheduled") }
  scope :due, ->(now = Time.current) { scheduled.where(due_at: ..now) }
  scope :wake_in_custody, -> { where(status: "activated", wake_state: IN_CUSTODY) }
  scope :recent_first, -> { order(Arel.sql("CASE WHEN status = 'scheduled' THEN 0 ELSE 1 END"), due_at: :desc, id: :desc) }

  def self.normalise(text)
    text.to_s.strip.gsub(/\s+/, " ").downcase
  end

  def self.digest_for(text)
    Digest::SHA256.hexdigest(normalise(text))
  end

  # A headline cut from a text when the resident gave no summary: its first
  # line with any Markdown lead stripped, up to the end of the first
  # sentence, at most HEADLINE_WORDS words. Older commitments and callers
  # that predate the summary get this.
  def self.headline_from(text)
    line = text.to_s.lines.map(&:strip).find(&:present?).to_s
    line = line.sub(/\A(?:[>#*\-+]+\s*|\d+[.)]\s+)+/, "").strip
    sentence = line.split(/(?<=[.!?])\s+/).first.to_s
    words = sentence.split(/\s+/)
    headline = words.first(HEADLINE_WORDS).join(" ")
    headline = "#{headline.sub(/[\s,;:.]+\z/, '')}…" if words.size > HEADLINE_WORDS
    headline.truncate(SUMMARY_LENGTH, omission: "…")
  end

  # What the "Commitment due" message and a new conversation's title show.
  def headline
    summary.presence || self.class.headline_from(text)
  end

  def scheduled? = status == "scheduled"
  def activated? = status == "activated"
  def cancelled? = status == "cancelled"
  def new_conversation? = destination == "new_conversation"
  def recurring? = recur_min_minutes.present?

  # The id every occurrence of a series shares: the first row's.
  def series_key
    series_root_id || id
  end

  def series_scope
    Commitment.where(id: series_key).or(Commitment.where(series_root_id: series_key))
  end

  # "every 60 minutes" or "every 60–90 minutes".
  def recurrence_phrase
    return unless recurring?

    span = recur_min_minutes == recur_max_minutes ? recur_min_minutes.to_s : "#{recur_min_minutes}–#{recur_max_minutes}"
    "every #{span} minutes"
  end

  # A person may cancel or reschedule when they own the house the
  # commitment lives in or the resident's own house.
  def manageable_by?(user)
    return false unless user

    account.owned_by?(user) || agent.account&.owned_by?(user)
  end

  def manageable_by_agent?(candidate)
    candidate.present? && candidate.id == agent_id
  end

  # The room a new conversation opens in; nil is Main. The API resolves the
  # account's resident room when no room is named, so a nil here is Main on
  # purpose or a chosen room that has since been removed.
  def destination_room
    room if room && room.account_id == account_id
  end

  # The house owner's zone as an IANA identifier ("Europe/Madrid"), which
  # browsers' Intl accepts. Profiles store Rails names ("Madrid"), which it
  # does not.
  def timezone
    zone = ActiveSupport::TimeZone[account.owner&.timezone.presence || "UTC"] || ActiveSupport::TimeZone["UTC"]
    zone.tzinfo.identifier
  end

  # Cancel before it is due, or stop the house waking for it while the wake
  # is still in custody. Stopping withdraws only this commitment's own
  # source on a held wake, so a wake shared with other requests still
  # carries theirs, and a run not yet claimed is refused at claim
  # (claim_refusal_reason). A run already claimed cannot be recalled.
  def cancel!(by:)
    with_series_lock do
      ended = recurring? ? end_series!(by: by, reason: "cancelled") : 0
      next Result.new(status: ended.positive? ? :series_ended : :not_cancellable) unless cancellable?

      in_custody = activated?
      withdraw_wake_source! if in_custody
      update!(status: "cancelled", cancelled_at: Time.current,
              wake_state: in_custody ? "withdrawn" : wake_state,
              cancelled_by_user: by.is_a?(User) ? by : nil, cancelled_by_agent: by.is_a?(Agent) ? by : nil,
              series_ended_reason: recurring? ? "cancelled" : series_ended_reason)
      Result.new(status: :cancelled)
    end
  end

  # The series' scheduled occurrence other than this one, if the series is
  # still live (at most one exists).
  def live_successor
    return unless recurring?

    series_scope.scheduled.where.not(id: id).order(:due_at).first
  end

  # Why the series ended, read from the whole series: cancellation writes
  # only the rows it stops.
  def series_end_reason
    return unless recurring?
    return if scheduled? || live_successor

    series_scope.where.not(series_ended_reason: nil).order(:id).last&.series_ended_reason || "ended"
  end

  # Cancel the series' scheduled occurrences other than this one. Returns how
  # many. The caller holds the series lock (with_series_lock), which
  # activation also takes before its own row, so a successor inserted by a
  # concurrent activation is either committed before this query runs or
  # never inserted.
  def end_series!(by:, reason:)
    series_scope.scheduled.where.not(id: id).order(:id).to_a.count do |other|
      other.with_lock do
        next false unless other.scheduled?

        other.update!(status: "cancelled", cancelled_at: Time.current, series_ended_reason: reason,
                      cancelled_by_user: by.is_a?(User) ? by : nil, cancelled_by_agent: by.is_a?(Agent) ? by : nil)
        true
      end
    end
  end

  def cancellable?
    scheduled? || (activated? && wake_state.in?(IN_CUSTODY))
  end

  def reschedule!(due_at:)
    with_lock do
      next Result.new(status: :not_scheduled) unless scheduled?

      assign_attributes(due_at: due_at, waiting_reason: nil, last_attempted_at: nil)
      self.reschedule_count += 1 if will_save_change_to_due_at?
      next Result.new(status: :invalid) unless save

      Result.new(status: :rescheduled)
    end
  end

  # The sweep's work for one row. Idempotent: anything but a scheduled row
  # that is due returns without effect.
  def activate!(now: Time.current)
    with_series_lock do
      next Result.new(status: :not_scheduled) unless scheduled?
      next Result.new(status: :not_due) if due_at > now

      if (reason = waiting_reason_now)
        update!(waiting_reason: reason, last_attempted_at: now)
        next Result.new(status: :waiting, reason: reason)
      end

      # One wake owed per series: while an earlier occurrence's wake is still
      # in the house's custody (woken, held, retrying), this one posts
      # nothing and moves a full interval on, so a resident busy in the
      # destination never builds up a queue of held wakes.
      if recurring? && series_scope.wake_in_custody.where.not(id: id).exists?
        update!(due_at: now + next_interval_minutes.minutes, waiting_reason: "previous_occurrence_in_progress",
                last_attempted_at: now)
        next Result.new(status: :waiting, reason: "previous_occurrence_in_progress")
      end

      chat = new_conversation? ? (series_conversation || open_conversation!) : source_chat
      # Activated before the successor exists: the unique index allows one
      # scheduled row per text, and the successor carries the same text.
      update!(status: "activated", activated_at: now, activation_chat: chat, waiting_reason: nil, last_attempted_at: now)
      successor = schedule_next!(now) if recurring?
      message = chat.messages.create!(role: "system", content: activation_text(chat, now, successor), suppress_automatic_dispatch: true)
      update!(activation_message: message)
      wake!
      Result.new(status: :activated)
    end
  end

  # The sweep's custody step for an activated row: follow the wake to its
  # outcome and wake again when it was lost before a run started. Never posts.
  def sync_wake!(allow_retry: true)
    with_lock do
      next unless activated? && wake_state.in?(IN_CUSTODY)
      next update!(wake_state: "blocked", wake_reason: "conversation_gone") unless activation_chat && activation_message

      case wake_state
      when "held" then follow_held_wake!
      when "woken" then follow_run!
      when "retrying" then attempt_wake! if allow_retry
      end
    end
  end

  # Why a run waking this commitment must not start now, or nil. Checked
  # when the run claims (AgentRuntimeInteraction#claim_commitment!).
  def claim_refusal_reason
    return "commitment_#{status}" unless activated?

    waiting_reason_now(activation_chat)
  end

  # The cue a run waking this commitment carries in its request.
  def cue_text
    due_local = due_at.in_time_zone(timezone)
    quoted = text.to_s.strip.lines.map { |line| "> #{line.rstrip}" }.join("\n")
    "Commitment due: you committed to this for #{due_local.strftime('%-d %b %Y %H:%M')} #{timezone}. " \
      "The house posted its headline (\"#{headline}\") in this conversation as message " \
      "#{activation_message&.to_param}; the full text you wrote is here, not in that message.\n\n#{quoted}\n\n" \
      "This returns it to your attention; it is not an order. Check the current state and decide what makes sense now." +
      recurrence_cue
  end

  def recurrence_cue
    return "" unless recurring?

    upcoming = live_successor
    if upcoming
      next_local = upcoming.due_at.in_time_zone(timezone)
      "\n\nThis commitment recurs #{recurrence_phrase} (this is occurrence #{occurrence}#{" of at most #{recur_max_occurrences}" if recur_max_occurrences}). The next is commitment " \
        "#{upcoming.to_param}, due #{next_local.strftime('%-d %b %H:%M')} #{timezone}. If what it is for is done, " \
        "end the series: `soulshouse-commitment cancel #{upcoming.to_param}`. Otherwise do nothing and it comes back."
    else
      reason = series_end_reason
      "\n\nThis commitment recurred #{recurrence_phrase} (this is occurrence #{occurrence}); the series has ended" \
        "#{reason && reason != 'ended' ? " (#{reason.tr('_', ' ')})" : ''}, so nothing follows it."
    end
  end

  def as_json(*)
    {
      id: to_param,
      text: text,
      summary: summary,
      headline: headline,
      status: status,
      essential: essential,
      due_at: due_at&.iso8601,
      due_at_local: due_at&.in_time_zone(timezone)&.iso8601,
      timezone: timezone,
      destination: destination,
      room_id: room&.to_param,
      room_name: room&.name,
      resident_id: agent.to_param,
      resident_name: agent.name,
      source_conversation_id: source_chat&.to_param,
      source_conversation_title: source_chat&.private? ? "A private conversation" : source_chat&.title_or_default,
      source_message_id: source_message&.to_param,
      waiting_reason: waiting_reason,
      last_attempted_at: last_attempted_at&.iso8601,
      activated_at: activated_at&.iso8601,
      activation_conversation_id: activation_chat&.to_param,
      activation_message_id: activation_message&.to_param,
      wake_state: wake_state,
      wake_reason: wake_reason,
      wake_runs: wake_runs,
      last_wake_at: last_wake_at&.iso8601,
      delivered_at: delivered_at&.iso8601,
      cancelled_at: cancelled_at&.iso8601,
      cancelled_by: cancelled_by_agent&.name || cancelled_by_user&.full_name.presence,
      cancellable: cancellable?,
      reschedule_count: reschedule_count,
      recurrence: recurring? ? { min_minutes: recur_min_minutes, max_minutes: recur_max_minutes, max_occurrences: recur_max_occurrences, phrase: recurrence_phrase } : nil,
      occurrence: occurrence,
      series_id: recurring? ? Commitment.new(id: series_key).to_param : nil,
      previous_commitment_id: previous_commitment&.to_param,
      next_commitment_id: next_commitment&.to_param,
      series_next_commitment_id: live_successor&.to_param,
      series_ended_reason: series_end_reason,
      created_at: created_at&.iso8601
    }
  end

  # What the resident is told when it saves: only after the save succeeded.
  def receipt
    where = new_conversation? ? "a new conversation in #{destination_room&.name || 'Main'}" : "this conversation"
    local = due_at.in_time_zone(timezone)
    "Commitment #{to_param} scheduled for #{local.strftime('%-d %b %Y %H:%M')} #{timezone} " \
      "(#{due_at.utc.iso8601}), in #{where}." +
      (recurring? ? " It recurs #{recurrence_phrase} after each delivery until you cancel it." : "")
  end

  # A house line in the conversation the commitment was made in, so the
  # people there see the promise when it is made, not only when it comes due
  # (Daniel, YnwNve JbakNy). Headline only, as with "Commitment due": the
  # full text can be private. A system message, so it wakes nobody and
  # carries no handoff. A commitment that opens a new conversation is still
  # announced here, where it was made: that conversation does not exist until
  # it is due. Posted once, by the resident API's create; rescheduling and
  # cancelling post nothing. A failure to post (the save, or a callback such
  # as a broadcast) never undoes the commitment or fails the create; it is
  # logged and not retried.
  #
  # Plain text on one line: system messages render as plain text
  # (MessageBubble's system branch has no Markdown), so `**` would show as
  # asterisks and a newline collapses into a space (#842). The " · " before
  # "due" keeps the headline from running into the date.
  def announce!
    return unless scheduled? && persisted?

    source_chat.messages.create!(role: "system", content: announcement_text, suppress_automatic_dispatch: true)
  rescue StandardError => error
    Rails.logger.warn("[Commitment#announce!] #{to_param}: #{error.class}: #{error.message}")
    nil
  end

  def announcement_text
    local = due_at.in_time_zone(timezone)
    text = "#{agent.name} made a commitment: #{headline} · due #{local.strftime('%a %-d %b %H:%M')} #{timezone}"
    text += " · recurs #{recurrence_phrase}" if recurring?
    text += " · will open a new conversation in #{destination_room&.name || 'Main'}" if new_conversation?
    text
  end

  private

  # The next occurrence of a recurring series, due a fixed or random number
  # of minutes after this one activates. Built from this row's own (already
  # valid) attributes and saved without re-running the create validations:
  # if the resident has since left the source conversation or the room was
  # archived, the successor still exists and waits with that reason, as any
  # commitment does, rather than silently ending the series. Inside a
  # savepoint so a failure ends the series with a reason and never undoes
  # the activation.
  def schedule_next!(now)
    if recur_max_occurrences && occurrence >= recur_max_occurrences
      self.series_ended_reason = "max_occurrences_reached"
      return nil
    end

    minutes = next_interval_minutes
    successor = Commitment.new(
      account: account, agent: agent, source_chat: source_chat, source_message: source_message,
      text: text, summary: summary, destination: destination, room: room, essential: essential,
      recur_min_minutes: recur_min_minutes, recur_max_minutes: recur_max_minutes, recur_max_occurrences: recur_max_occurrences,
      series_root_id: series_key, previous_commitment: self, occurrence: occurrence + 1,
      due_at: now + minutes.minutes
    )
    Commitment.transaction(requires_new: true) { successor.save!(validate: false) }
    successor
  rescue ActiveRecord::ActiveRecordError => error
    Rails.logger.warn("[Commitment#schedule_next!] #{to_param}: #{error.class}: #{error.message}")
    self.series_ended_reason = "next_occurrence_failed"
    nil
  end

  def next_interval_minutes
    recur_min_minutes == recur_max_minutes ? recur_min_minutes : rand(recur_min_minutes..recur_max_minutes)
  end

  # The series lock is the first row's lock, taken before this row's. Every
  # recurring activation and every cancel takes it, so they serialise per
  # series (Mira, #1176 P1). A one-shot commitment, and the first row
  # itself, just lock their own row.
  def with_series_lock(&block)
    return with_lock(&block) unless recurring? && series_root_id

    Commitment.transaction do
      Commitment.lock.find_by(id: series_root_id)
      with_lock(&block)
    end
  end

  def recurrence_valid
    if recur_max_occurrences && (recur_min_minutes.nil? || !recur_max_occurrences.between?(1, RECUR_MAX_OCCURRENCES))
      errors.add(:base, "A maximum number of occurrences needs a recurrence, and must be between 1 and #{RECUR_MAX_OCCURRENCES}")
    end
    return if recur_min_minutes.nil? && recur_max_minutes.nil?

    if recur_min_minutes.nil? || recur_max_minutes.nil?
      errors.add(:base, "A recurrence needs both a minimum and a maximum (equal for a fixed interval)")
    elsif recur_min_minutes < RECUR_MIN_MINUTES || recur_max_minutes > RECUR_MAX_MINUTES
      errors.add(:base, "A recurrence must be between #{RECUR_MIN_MINUTES} minutes and #{RECUR_MAX_MINUTES / 1440} days")
    elsif recur_min_minutes > recur_max_minutes
      errors.add(:base, "A recurrence's minimum cannot be more than its maximum")
    end
  end

  def sidebar_mark_changed?
    return false unless destination == "same_conversation" || saved_change_to_destination?
    return true if destroyed? || previously_new_record?

    saved_change_to_status? || saved_change_to_due_at? || saved_change_to_source_chat_id? || saved_change_to_destination?
  end

  def refresh_sidebar_mark
    chat_account = source_chat&.account
    return unless chat_account

    ActionCable.server.broadcast("Account:#{chat_account.obfuscated_id}", { action: "refresh", prop: "chats" })
    # The open conversation's header shows the same mark (#869) and reloads its
    # own `chat` prop from the Chat channel, so it updates even when the
    # conversation is filtered out of the sidebar list. A move tells both.
    chat_ids = [ source_chat_id, (source_chat_id_previously_was if saved_change_to_source_chat_id?) ].compact.uniq
    Chat.where(id: chat_ids).find_each do |chat|
      ActionCable.server.broadcast("Chat:#{chat.obfuscated_id}", { action: "refresh", prop: "chat" })
    end
  end

  def set_account
    self.account ||= source_chat&.account
  end

  def set_text_digest
    self.text_digest = self.class.digest_for(text) if text
  end

  # A trigger source stands while its requester is in the room
  # (PendingWakeSource#standing?); clearing the requester withdraws it and
  # keeps the record. The wake's release drops it if nothing else stands.
  # Whatever the wake state: a held wake released to a run that has not
  # claimed yet is authorised by its sources at claim
  # (AgentRuntimeInteraction#claim_released_wake!), so this one must go
  # even after sync has followed the release to "woken".
  def withdraw_wake_source!
    return unless pending_wake_source

    pending_wake_source.update_columns(requester_agent_id: nil, updated_at: Time.current)
  end

  def record_delivery!
    update!(wake_state: "delivered", wake_reason: nil, delivered_at: Time.current)
  end

  def retry_later!(why)
    update!(wake_state: "retrying", wake_reason: why)
  end

  def follow_held_wake!
    wake = pending_wake
    if wake.nil?
      retry_later!("held wake lost")
    elsif wake.dropped_at
      retry_later!("held wake dropped: #{wake.drop_reason}")
    elsif wake.released_at
      run = wake.released_interaction
      return retry_later!("held wake released without a run") unless run

      update!(wake_state: "woken", wake_interaction: run, wake_runs: wake_runs + 1)
      follow_run!
    end
  end

  # Delivered when the run carrying the cue ended ok. A run cancelled or
  # refused before it started goes back to retrying; any other ending may
  # have reached the runtime, so it is recorded and not replayed.
  def follow_run!
    run = wake_interaction
    return retry_later!("run lost") unless run
    return unless run.finished_at

    if run.transport_status.to_i.between?(200, 299) && run.runtime_status == "ok"
      record_delivery!
    elsif run.execution_state == "busy" || (run.execution_state == "cancelled" &&
        (run.dispatch_claimed_at.nil? || ResidentTurn.where(agent_runtime_interaction_id: run.id)
          .where("completion_context->>'allowance_brake_refused' = 'true'").exists?))
      retry_later!("run #{run.execution_state} before it started")
    else
      update!(wake_state: "blocked", wake_reason: "run ended #{run.execution_state}; not replayed")
    end
  end

  def attempt_wake!
    if wake_runs >= MAX_WAKE_RUNS
      return update!(wake_state: "blocked", wake_reason: "#{wake_reason}; gave up after #{wake_runs} runs")
    end
    if (reason = waiting_reason_now(activation_chat))
      return update!(wake_reason: reason)
    end

    wake!
  end

  def due_in_future
    errors.add(:due_at, "must be in the future") if due_at && due_at <= Time.current
  end

  def resident_in_source
    return unless source_chat && agent

    errors.add(:agent, "must be in the conversation it commits from") unless source_chat.agents.exists?(agent.id)
  end

  def source_message_in_source
    return unless source_message

    errors.add(:source_message, "must be in the source conversation") unless source_message.chat_id == source_chat_id
  end

  def private_source_stays_home
    return unless source_chat&.private? && destination != "same_conversation"

    errors.add(:destination, "must be this conversation for a commitment made in a private conversation")
  end

  def room_valid
    if new_conversation?
      return unless new_record? || will_save_change_to_room_id? || will_save_change_to_destination?

      errors.add(:room, "must be a room of this account") if room && room.account_id != account_id
      errors.add(:room, "#{room.name} is archived") if room&.archived?
    elsif room_id
      errors.add(:room, "is only for a new conversation")
    end
  end

  def text_unique_while_scheduled
    others = Commitment.scheduled.where(agent_id: agent_id, text_digest: text_digest)
    others = others.where.not(id: id) if persisted?
    existing = others.first
    return unless existing

    errors.add(:text, "is the same as scheduled commitment #{existing.to_param} " \
      "(due #{existing.due_at.utc.iso8601}); give each commitment its own text")
  end

  # Why the commitment cannot be delivered right now, or nil. Nothing is
  # posted (or woken) while there is a reason; the sweep tries again. chat is
  # the conversation it is delivered in, when there is one yet.
  def waiting_reason_now(chat = new_conversation? ? nil : source_chat)
    return "live_activity_disabled" unless AgentRuntimeInteraction.live_activity_enabled?
    return "resident_not_member" unless account.conversation_agents.exists?(agent_id)

    agent.reload
    return "billing_hold" if agent.billing_held?
    return "resident_paused" if agent.paused?
    return "resident_unavailable" unless agent.eligible_for_conversation?

    if chat
      chat.reload
      return "conversation_unavailable" unless chat.respondable? && chat.manual_responses?
      return "resident_not_in_conversation" unless chat.agents.exists?(agent_id)
    end
    Agents::AllowanceBrake.commitment_reason(self, chat: chat)
  end

  # A recurring series that opens a conversation opens one, on its first
  # delivered occurrence, and later occurrences recur inside it, so a
  # goal-shaped series keeps one working thread (Reed, eRNlOe eaMwXx). If that
  # conversation can no longer take the wake, the next occurrence opens a
  # fresh one and the series carries on there.
  def series_conversation
    return unless recurring?

    chat = series_scope.where.not(id: id).where.not(activation_chat_id: nil).order(occurrence: :desc).first&.activation_chat
    chat if chat&.respondable? && chat.manual_responses? && chat.agents.exists?(agent_id)
  end

  def open_conversation!
    account.chats.create_with_message!(
      { title: conversation_title, manual_responses: true, room: destination_room },
      agent_ids: [ agent_id ], automatic_response: false
    )
  end

  def conversation_title
    "Commitment: #{headline.truncate(TITLE_LENGTH - 12)}"
  end

  # One headline and one line of facts. The full text stays with the
  # resident (cue_text) and on the resident's page.
  def activation_text(chat, now, successor = nil)
    due_local = due_at.in_time_zone(timezone)
    now_local = now.in_time_zone(timezone)
    when_line = "due #{due_local.strftime('%-d %b %H:%M')} #{timezone}"
    when_line += if (now - due_at) >= 60
      ", delivered #{now_local.strftime('%-d %b %H:%M')} (late)"
    else
      ", delivered #{now_local.strftime('%H:%M')}"
    end
    made = "made #{created_at.in_time_zone(timezone).strftime('%-d %b %H:%M')}"
    origin = if chat.id == source_chat_id
      "#{made} here" + (source_message ? " (message #{source_message.to_param})" : "")
    else
      # A private source is never named in another room (eKmnrJ).
      (if source_chat.private?
         "#{made} in a private conversation"
       else
         "#{made} in [#{source_chat.title_or_default}](/accounts/#{account.to_param}/chats/#{source_chat.to_param})"
       end) +
        (source_message ? " (message #{source_message.to_param})" : "")
    end
    recurs = if successor
      " · recurs #{recurrence_phrase}, next #{successor.due_at.in_time_zone(timezone).strftime('%H:%M')}"
    elsif recurring? && series_ended_reason == "max_occurrences_reached"
      " · recurring, and this is the last of #{recur_max_occurrences} occurrences"
    elsif recurring?
      " · recurring, but the next occurrence could not be scheduled"
    else
      ""
    end
    "**Commitment due:** #{headline}\n\n#{agent.name} · #{when_line} · #{origin}#{recurs}"
  end

  # Wake the resident in the activation conversation, as a knock does
  # (MessageHandoff#dispatch!). The caller holds this row's lock; the chat
  # lock is taken inside, so the order is always commitment, then chat.
  def wake!
    chat = activation_chat
    chat.with_lock do
      result = chat.trigger_agent_response!(agent, wake_source_kinds: [ "scheduled" ])
      unless result.is_a?(AgentRuntimeInteraction)
        next update!(wake_state: "retrying", wake_reason: "no run to follow", last_wake_at: Time.current)
      end

      update!(wake_state: "woken", wake_reason: nil, wake_interaction: result, pending_wake: nil, pending_wake_source: nil,
              last_wake_at: Time.current, wake_runs: wake_runs + 1)
    rescue Chat::AlreadyResponding
      wake = PendingWake.queue!(chat: chat, agent: agent, requested_by: "#{agent.name}'s commitment",
        requester_agent: agent, wake_source_kinds: [ "scheduled" ])
      update!(wake_state: "held", wake_reason: nil, pending_wake: wake, pending_wake_source: wake.sources.order(:id).last,
              wake_interaction: nil, last_wake_at: Time.current)
    rescue Agent::RuntimeAvailability::Unavailable => error
      update!(wake_state: "retrying", wake_reason: "unavailable:#{error.code}", last_wake_at: Time.current)
    rescue ArgumentError => error
      update!(wake_state: "retrying", wake_reason: "refused: #{error.message.truncate(200)}", last_wake_at: Time.current)
    end
  end

  def normalise_summary
    self.summary = summary.to_s.gsub(/\s+/, " ").strip.presence
  end

end
