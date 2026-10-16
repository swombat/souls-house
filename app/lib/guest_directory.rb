# Hints for the existing guest/away lists, never personal candidate discovery.
# HTTP presenters remain authoritative; no directory contents cross this stream.
module GuestDirectory

  def self.refresh!(account_ids)
    ids = Array(account_ids).compact.uniq
    return if ids.empty?

    ActiveRecord.after_all_transactions_commit do
      Account.where(id: ids).select(:id).each do |account|
        ActionCable.server.broadcast("GuestDirectory:#{account.to_param}", { action: "refresh" })
      end
    end
  end

  # Capture before dependent delete_all removes the edges. Only immediate
  # guest relationships count: this must not fan out to other candidate homes.
  def self.account_ids_for(account_ids)
    ids = Array(account_ids).compact.uniq
    receiving_ids = GuestMembership.where(agent_id: Agent.where(account_id: ids).select(:id)).pluck(:account_id)
    home_ids = Agent.where(id: GuestMembership.where(account_id: ids).select(:agent_id)).pluck(:account_id)
    (ids + receiving_ids + home_ids).uniq
  end

  def self.refresh_personal_labels!(user_ids)
    ids = Membership.owners.where(user_id: user_ids).select(:account_id)
    refresh!(account_ids_for(Account.personal.where(id: ids).ids))
  end

end
