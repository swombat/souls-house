# A rhythm pinned a resident to a model that has left the resident's list, and
# no successor of it is on the list either (Agents::ModelSuccession), so every
# occurrence is refused. The occurrence gets the room line
# (ConversationModelEvent.unavailable!), but nobody reads an unattended
# occurrence, and rhythm runs are conversation runs, so the scheduled-run
# streak email (ScheduledRunFailureNotice) never sees them (Mira, JlRlKe).
#
# This tells the account's owner once per rhythm seat and stale model: the
# audit row is the latch, written under a lock on the rhythm seat, so racing
# or repeated occurrences send one email. A later stale pin on another model
# is a new notice.
class StaleRhythmPinNotice

  ACTION = "rhythm_model_pin_stale".freeze

  # Never raises into the refusal path: a notice that can't be written must
  # not turn a visible refusal into an error.
  def self.observe!(agent:, chat:, model_id:)
    occurrence = RhythmOccurrence.find_by(chat_id: chat.id)
    return unless occurrence&.rhythm_id

    seat = RhythmAgent.find_by(rhythm_id: occurrence.rhythm_id, agent_id: agent.id)
    return unless seat

    seat.with_lock do
      # with_lock reloads the seat: a pin changed meanwhile is not stale.
      next unless seat.model_id == model_id.to_s
      next if AuditLog.where(action: ACTION, auditable: seat).where("data->>'model_id' = ?", model_id.to_s).exists?

      owner = seat.rhythm.account.owner
      row = AuditLog.create!(user: nil, account: seat.rhythm.account, action: ACTION, auditable: seat,
        data: { rhythm_id: seat.rhythm_id, agent_id: agent.id, model_id: model_id.to_s, chat_id: chat.id, emailed: owner.present? })
      ActiveRecord.after_all_transactions_commit { ResidentHealthMailer.rhythm_model_pin_stale(row).deliver_later } if owner
      row
    end
  rescue StandardError => error
    Rails.logger.warn "[StaleRhythmPinNotice] chat #{chat&.id} agent #{agent&.id}: #{error.class}: #{error.message}"
    nil
  end

end
