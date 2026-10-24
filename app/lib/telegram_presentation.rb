# Count/configuration hints only. Never carries registration links or bot tokens.
module TelegramPresentation

  def self.refresh!(agent_ids)
    ids = Array(agent_ids).compact.uniq
    ActiveRecord.after_all_transactions_commit do
      Agent.where(id: ids).select(:id).each do |agent|
        ActionCable.server.broadcast("TelegramPresentation:#{agent.to_param}", { action: "refresh" })
      end
    end
  end

end
