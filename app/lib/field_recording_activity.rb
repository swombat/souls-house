# Presentation-only hints on the existing, account-authorized recording stream.
# Do not touch recording rows here: forget intentionally holds only a voice lock,
# and taking a recording write lock there would invert the naming lock order.
module FieldRecordingActivity

  def self.refresh!(recording_ids)
    ids = Array(recording_ids).compact.uniq
    return if ids.empty?

    transaction = ApplicationRecord.current_transaction
    if transaction.closed?
      FieldRecording.where(id: ids).select(:id).each do |recording|
        ActionCable.server.broadcast("FieldRecording:#{recording.to_param}", { action: "refresh", prop: "field_recording" })
      end
      return
    end

    # The FieldTweetStream registry pattern: callbacks wait for the outer
    # commit, disappear on rollback and coalesce producing writes. Separate
    # committed savepoints can each contribute a marker.
    pending = ActiveSupport::IsolatedExecutionState[:field_recording_activity_refreshes] ||= {}
    unless pending.key?(transaction)
      pending[transaction] = []
      transaction.after_rollback { pending.delete(transaction) }
      transaction.after_commit { refresh!(pending.delete(transaction)) }
    end
    pending[transaction] |= ids
  end

end
