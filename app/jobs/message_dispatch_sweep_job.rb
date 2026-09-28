# Every minute: re-drive dispatches whose enqueue may have been lost, record
# expiry, and recover their runs and chain continuations (#94 B, step 4b-ii).
# Scoped to recent dispatches, so it never wakes a chain no dispatch started.
class MessageDispatchSweepJob < ApplicationJob

  def perform
    MessageDispatch.recoverable.where(status: %w[pending reserved]).find_each(&:redrive!)
  end

end
