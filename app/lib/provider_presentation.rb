# Persisted provider presentation only: no credentials or ceremony content.
# Scoped HTTP presenters remain authoritative.
module ProviderPresentation

  def self.refresh!(account_ids)
    ids = Array(account_ids).compact.uniq
    ActiveRecord.after_all_transactions_commit do
      Account.where(id: ids).select(:id).each do |account|
        ActionCable.server.broadcast("ProviderPresentation:#{account.to_param}", { action: "refresh" })
      end
    end
  end

end
