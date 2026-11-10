# A content-free hint that an account's Computers page should reload its
# devices: a computer connected or dropped, was paused, resumed or removed,
# its permissions changed, or it sent its report. The page reloads through
# its own authorised controller; nothing about the device is in the message.
module ComputerStatus

  def self.refresh!(account)
    stream = "ComputerStatus:#{account.to_param}"
    ActiveRecord.after_all_transactions_commit do
      ActionCable.server.broadcast(stream, { action: "refresh" })
    end
  end

end
