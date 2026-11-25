# Account-authorized, content-free hints that an account's practices changed,
# so an open Practices page refreshes. HTTP remains the authority.
module PracticeActivity

  def self.refresh!(account_id)
    ActiveRecord.after_all_transactions_commit do
      account = Account.select(:id).find_by(id: account_id)
      ActionCable.server.broadcast("PracticeActivity:#{account.to_param}", { action: "refresh" }) if account
    end
  end

end
