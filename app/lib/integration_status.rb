# A content-free hint to reload the existing, user-authorized presenters.
# Personal changes intentionally share this account-level timing signal.
module IntegrationStatus

  def self.refresh!(accounts)
    ids = Array(accounts).compact.map { |account| account.is_a?(Account) ? account.id : account }.uniq
    streams = Account.where(id: ids).select(:id).map { |account| "IntegrationStatus:#{account.to_param}" }
    ActiveRecord.after_all_transactions_commit do
      streams.each { |stream| ActionCable.server.broadcast(stream, { action: "refresh" }) }
    end
  end

end
