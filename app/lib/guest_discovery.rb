# Personal candidate discovery across a human's other confirmed accounts.
# Hints contain no home/resident identifiers; scoped HTTP queries decide visibility.
module GuestDiscovery

  def self.refresh!(user_ids)
    ids = Array(user_ids).compact.uniq
    return if ids.empty?

    ActiveRecord.after_all_transactions_commit do
      User.where(id: ids).select(:id).each do |user|
        ActionCable.server.broadcast("GuestDiscovery:#{user.to_param}", { action: "refresh" })
      end
    end
  end

  def self.user_ids_for(account_ids)
    Membership.confirmed.where(account_id: Array(account_ids).compact).distinct.pluck(:user_id)
  end

  def self.refresh_accounts!(account_ids)
    # Snapshot on each write, not after commit: memberships may disappear later
    # in this transaction (especially during dependent account destruction).
    refresh!(user_ids_for(account_ids))
  end

end
