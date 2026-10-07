# A rhythm run that nobody needs to act on stays off the conversation list and
# lives on its rhythm's page instead. A run is quiet while all of these hold:
#
# - a rhythm that still exists started it (a deleted rhythm nulls the
#   occurrence's rhythm_id, and its runs come back to the list rather than
#   becoming reachable only by search);
# - it has exactly one resident;
# - no person has posted in it, apart from the rhythm's own opening message
#   (a person-created rhythm opens with a message in that person's name);
# - nothing in it has ever been flagged for a person (a ReplyExpectation in
#   any state, so dismissing the eye does not hide the run again).
#
# The conditions are evaluated from the rows themselves, so promotion needs no
# state of its own: a person replying, the eye appearing, or a second resident
# taking a seat each make the run an ordinary listed conversation.
module Chat::QuietRhythmRun

  extend ActiveSupport::Concern

  QUIET_RHYTHM_RUN_SQL = <<~SQL.squish.freeze
    EXISTS (SELECT 1 FROM rhythm_occurrences ro WHERE ro.chat_id = chats.id AND ro.rhythm_id IS NOT NULL)
    AND (SELECT COUNT(*) FROM chat_agents ca WHERE ca.chat_id = chats.id) = 1
    AND NOT EXISTS (
      SELECT 1 FROM messages m
      WHERE m.chat_id = chats.id AND m.role = 'user' AND m.discarded_at IS NULL
        AND m.id NOT IN (SELECT ro2.message_id FROM rhythm_occurrences ro2 WHERE ro2.chat_id = chats.id)
    )
    AND NOT EXISTS (
      SELECT 1 FROM reply_expectations re JOIN messages fm ON fm.id = re.message_id
      WHERE fm.chat_id = chats.id
    )
  SQL

  included do
    # The database cascades occurrences with their chat.
    has_many :rhythm_occurrences

    scope :quiet_rhythm_runs, -> { where(QUIET_RHYTHM_RUN_SQL) }
    scope :listed, -> { where.not(QUIET_RHYTHM_RUN_SQL) }
  end

  def quiet_rhythm_run?
    persisted? && self.class.quiet_rhythm_runs.exists?(id: id)
  end

  def rhythm_run?
    rhythm_occurrences.exists?
  end

  # The sidebar refreshes its list when the chat broadcasts. A flag or a new
  # seat changes whether a run is listed without touching the chat itself.
  def announce_listing_change
    touch if persisted? && !destroyed? && rhythm_run?
  rescue StandardError => error
    # The flag or seat has committed; a missed list refresh is not a failure.
    Rails.logger.warn("[Chat] #{id} listing refresh failed: #{error.class}")
  end

end
