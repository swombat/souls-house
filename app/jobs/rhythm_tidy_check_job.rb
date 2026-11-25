# Asks a multi-resident rhythm run's last finisher, once, whether to tidy the
# run away (RhythmTidy). Enqueued whenever a conversation run in a rhythm's
# chat finishes; while anything there is still running or owed a wake it does
# nothing, and the next run to finish enqueues it again.
#
# Settled once per occurrence: tidy_asked_at is written under the chat and
# occurrence locks, in the same transaction as the wake's reservation, so
# duplicate jobs ask at most once and a wake is never recorded without its
# marker. A run that can't be asked about (a person spoke, it was tagged or
# flagged, nobody to ask, the resident's allowance brake on, or the last
# opening turn ended longer ago than RhythmTidy::CACHE_WINDOW) is settled too,
# without a wake.
class RhythmTidyCheckJob < ApplicationJob

  DELAY = 30.seconds

  queue_as :default
  limits_concurrency to: 1, key: ->(occurrence_id) { "rhythm-tidy-#{occurrence_id}" }

  def perform(occurrence_id)
    occurrence = RhythmOccurrence.find_by(id: occurrence_id)
    return unless occurrence && occurrence.tidy_asked_at.nil?
    return unless AgentRuntimeInteraction.live_activity_enabled?

    chat = occurrence.chat
    chat.transaction do
      chat.lock!
      occurrence.lock!
      next unless occurrence.tidy_asked_at.nil?

      tidy = RhythmTidy.new(occurrence)
      reason = tidy.refusal_reason
      next if reason == :busy
      next settle!(occurrence) if reason

      next settle!(occurrence) if tidy.past_cache_window?
      agent = tidy.last_finisher&.lock!
      next settle!(occurrence) unless agent && !agent.paused? && tidy.ways_for(agent)
      next settle!(occurrence) if Agents::AllowanceBrake.rhythm_tidy_reason(agent, chat)

      wake = AgentRuntimeInteraction.reserve!(agent: agent, chat: chat, enqueue: true,
        wake_source_kinds: [ "scheduled" ], requested_at: Time.current)
      occurrence.update!(tidy_asked_at: Time.current, tidy_interaction: wake)
    end
  rescue Chat::AlreadyResponding
    # Someone started a run since the check; its finish enqueues this again.
    nil
  rescue Agent::RuntimeAvailability::Unavailable, Chat::ParticipantChanged => error
    Rails.logger.info("Rhythm tidy for occurrence #{occurrence_id} not asked: #{error.class}")
    RhythmOccurrence.where(id: occurrence_id, tidy_asked_at: nil).update_all(tidy_asked_at: Time.current)
  end

  private

  def settle!(occurrence)
    occurrence.update!(tidy_asked_at: Time.current)
  end

end
