# Presentation-only hints. Scoped HTTP presenters still own the roster,
# recognition affordances and member options; cable carries none of them.
module FieldVoiceActivity

  def self.refresh!(account_ids)
    ids = Array(account_ids).compact.uniq
    return if ids.empty?

    transaction = ApplicationRecord.current_transaction
    if transaction.closed?
      Account.where(id: ids).select(:id).each do |account|
        ActionCable.server.broadcast("FieldVoiceActivity:#{account.to_param}", { action: "refresh" })
      end
      return
    end

    # As in FieldTweetStream: capture producing writes, not final dirty state.
    # Rails transfers callbacks out of committed savepoints and drops rolled
    # back ones. Separate committed savepoints can each send a marker.
    pending = ActiveSupport::IsolatedExecutionState[:field_voice_activity_refreshes] ||= {}
    unless pending.key?(transaction)
      pending[transaction] = []
      transaction.after_rollback { pending.delete(transaction) }
      transaction.after_commit do
        refresh!(pending.delete(transaction))
      end
    end
    pending[transaction] |= ids
  end

  # Capture before User destruction removes memberships and the database
  # nullifies voice links.
  def self.account_ids_for_users(user_ids)
    ids = Array(user_ids).compact.uniq
    membership_ids = Membership.where(user_id: ids).pluck(:account_id)
    voice_ids = FieldVoice.kept.where(user_id: ids).pluck(:account_id)
    (membership_ids + voice_ids).uniq
  end

  def self.refresh_for_users!(user_ids)
    refresh!(account_ids_for_users(user_ids))
  end

end
