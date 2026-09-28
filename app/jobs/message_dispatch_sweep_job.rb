# Every minute: re-drive dispatches whose enqueue may have been lost, record
# expiry, and recover their runs and chain continuations (#94 B, step 4b-ii).
# Re-driving is scoped to recent dispatches, so it never wakes a chain no
# dispatch started. Recording outcomes is not: an expired dispatch or run is
# settled however long the outage was. One row's failure never stops the rest.
class MessageDispatchSweepJob < ApplicationJob

  def perform
    each_isolated(MessageDispatch.where(status: "pending").where(expires_at: ..Time.current), &:redrive!)
    each_isolated(MessageDispatch.recoverable.where(status: %w[pending reserved]), &:redrive!)
    each_isolated(MessageDispatch.recovery_open.where(accepted_at: ...MessageDispatch::RECOVERY_HORIZON.ago), &:close_recovery!)
  end

  private

  def each_isolated(scope)
    scope.find_each do |dispatch|
      yield dispatch
    rescue StandardError => e
      Rails.logger.error "[MessageDispatchSweepJob] dispatch #{dispatch.id}: #{e.class}: #{e.message}"
    end
  end

end
