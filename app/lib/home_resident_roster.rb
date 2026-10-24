# Home residents only; scoped HTTP presenters remain authoritative.
module HomeResidentRoster

  def self.refresh!(account_ids)
    ids = Array(account_ids).compact.uniq
    ActiveRecord.after_all_transactions_commit do
      Account.where(id: ids).select(:id).each do |account|
        ActionCable.server.broadcast("HomeResidentRoster:#{account.to_param}", { action: "refresh" })
      end
    end
  end

end
