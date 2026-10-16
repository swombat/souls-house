# A content-free hint to reload the account-authorized tweet stream presenter.
# Keep collection bookkeeping off FieldActivity and the account's other streams.
module FieldTweetStream

  def self.refresh!(accounts)
    ids = Array(accounts).compact.map { |account| account.is_a?(Account) ? account.id : account }.uniq
    streams = Account.where(id: ids).select(:id).map { |account| "FieldTweetStream:#{account.to_param}" }
    return if streams.empty?

    transaction = ApplicationRecord.current_transaction
    if transaction.closed?
      streams.each { |stream| ActionCable.server.broadcast(stream, { action: "refresh" }) }
      return
    end

    # Capture each write, not the model's final saved_changes. Rails transfers
    # these callbacks to the outer transaction, or drops them on rollback.
    # Coalesce within a transaction; separate committed savepoints may each
    # send a marker. No internal transaction stack or model-instance flags.
    pending = ActiveSupport::IsolatedExecutionState[:field_tweet_stream_refreshes] ||= {}
    unless pending.key?(transaction)
      pending[transaction] = []
      transaction.after_rollback { pending.delete(transaction) }
      transaction.after_commit do
        pending.delete(transaction).each do |stream|
          ActionCable.server.broadcast(stream, { action: "refresh" })
        end
      end
    end
    pending[transaction] |= streams
  end

end
