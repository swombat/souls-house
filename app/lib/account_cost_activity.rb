# Content-free hints, coalesced within a transaction/savepoint, not over time.
module AccountCostActivity

  def self.refresh!(account_ids)
    ids = Array(account_ids).compact.uniq
    return if ids.empty?

    transaction = ApplicationRecord.current_transaction
    unless transaction.open?
      broadcast(ids)
      return
    end

    # Transaction-owned state cannot leak after rollback. Savepoints own separate
    # sets, so a rolled-back inner write cannot poison a surviving outer hint.
    pending = transaction.instance_variable_get(:@account_cost_activity_ids)
    unless pending
      pending = Set.new
      transaction.instance_variable_set(:@account_cost_activity_ids, pending)
      transaction.after_commit { broadcast(pending.to_a) }
    end
    pending.merge(ids)
  end

  def self.broadcast(ids)
    Account.where(id: ids).select(:id).each do |account|
      ActionCable.server.broadcast("AccountCostActivity:#{account.to_param}", { action: "refresh" })
    end
  end
  private_class_method :broadcast

end
