# The recording allowance ledger (spec §6). One reservation per recording,
# ever (unique index). "Used" is every pending reservation at any age, plus
# consumed ones whose transcription finished in the last 7 days.
#
# Consume and release are guarded updates (WHERE state = 'pending'), so a
# duplicate does nothing. They never need the account lock: they only lower
# "used" or keep it the same, so they can't break an admission decision.
class FieldRecordingReservation < ApplicationRecord

  WINDOW = 7.days

  belongs_to :account
  belongs_to :field_recording

  state_machine :state, initial: :pending, action: nil do
    state :pending, :consumed, :released

    event :consume_allowance do
      transition pending: :consumed
    end

    event :release_allowance do
      transition pending: :released
    end
  end

  validates :audio_ms, numericality: { only_integer: true, greater_than: 0 }

  scope :counting_at, ->(now) {
    where(state: "pending").or(where(state: "consumed").where(consumed_at: (now - WINDOW)..))
  }

  def self.used_ms(account, now: Time.current)
    where(account:).counting_at(now).sum(:audio_ms)
  end

  # When enough consumed allowance will have aged out for `needed_ms` to fit.
  # nil when no estimate is honest: pending work alone leaves too little room,
  # or nothing consumed is due to expire (§6).
  def self.room_at(account, needed_ms, now: Time.current)
    limit = account.recording_ms_weekly_limit
    return now if used_ms(account, now:) + needed_ms <= limit

    pending_ms = where(account:, state: "pending").sum(:audio_ms)
    return nil if pending_ms + needed_ms > limit

    excess = used_ms(account, now:) + needed_ms - limit
    freed = 0
    where(account:, state: "consumed").where(consumed_at: (now - WINDOW)..).order(:consumed_at, :id).each do |row|
      freed += row.audio_ms
      return row.consumed_at + WINDOW if freed >= excess
    end
    nil
  end

  def self.over_limit_message(account, needed_ms, now: Time.current)
    left = [ account.recording_ms_weekly_limit - used_ms(account, now:), 0 ].max
    message = "This recording is #{format_duration(needed_ms)}. You have #{format_duration(left)} left this week."
    if needed_ms > account.recording_ms_weekly_limit
      "#{message} It's longer than this Field's whole weekly allowance."
    elsif (at = room_at(account, needed_ms, now:))
      "#{message} Room frees up gradually; enough for this one by about #{at.strftime('%a %-d %b, %H:%M')}."
    else
      "#{message} No estimate yet: other recordings are still transcribing."
    end
  end

  def self.format_duration(ms)
    minutes = (ms / 60_000.0).ceil
    hours, mins = minutes.divmod(60)
    hours.positive? ? "#{hours} h #{format('%02d', mins)} m" : "#{mins} m"
  end

  def consume!(now: Time.current)
    settle!(:consume_allowance, consumed_at: now, updated_at: now)
  end

  def release!(reason:, now: Time.current)
    settle!(:release_allowance, released_at: now, release_reason: reason, updated_at: now)
  end

  private

  private :consume_allowance, :consume_allowance!, :release_allowance, :release_allowance!

  def settle!(event, attributes)
    # Resolve the edge from pending, not this worker's cached state. The
    # database's compare-and-set decides the winner without a read/save race.
    transition = self.class.state_machine(:state).events[event].transition_for(self, from: :pending)
    changed = self.class.where(id:, state: transition.from)
      .update_all(attributes.merge(state: transition.to)) == 1
    reload
    changed
  end

end
