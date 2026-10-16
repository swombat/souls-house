# Presentation-only hints. Scoped HTTP presenters still own the roster,
# recognition affordances and member options; cable carries none of them.
module FieldVoiceActivity

  def self.refresh!(account_ids)
    ids = Array(account_ids).compact.uniq
    return if ids.empty?

    ActiveRecord.after_all_transactions_commit do
      Account.where(id: ids).select(:id).each do |account|
        ActionCable.server.broadcast("FieldVoiceActivity:#{account.to_param}", { action: "refresh" })
      end
    end
  end

  # Capture before User destruction removes memberships and the database
  # nullifies voice links. Former members can still be a remembered-by label.
  def self.account_ids_for_users(user_ids)
    ids = Array(user_ids).compact.uniq
    membership_ids = Membership.where(user_id: ids).pluck(:account_id)
    voice_ids = FieldVoice.kept.where(user_id: ids).pluck(:account_id)
    consent_voice_ids = FieldVoiceprint.where(consented_by_type: "User", consented_by_id: ids).select(:field_voice_id)
    consent_ids = FieldVoice.kept.where(id: consent_voice_ids).pluck(:account_id)
    (membership_ids + voice_ids + consent_ids).uniq
  end

  def self.refresh_for_users!(user_ids)
    refresh!(account_ids_for_users(user_ids))
  end

end
