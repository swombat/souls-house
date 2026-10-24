# Every minute: record what became of lapsed dispatches (#94 B, step 4b-ii).
# It never starts, re-enqueues or advances anything: a lost wake is not
# recovered, the person asks again (consultation BjAPDe). Pending dispatches
# past expiry become expired; reserved ones have runs whose deadline passed
# unclaimed cancelled, and past the horizon are closed. One row's failure
# never stops the rest.
class MessageDispatchSweepJob < ApplicationJob

  def perform
    each_isolated(MessageDispatch.where(status: "pending").where(expires_at: ..Time.current), &:settle_lapsed!)
    each_isolated(MessageDispatch.recovery_open, &:settle_lapsed!)
    # A resident's handoff whose knock never ran is recorded the same way.
    each_isolated(MessageHandoff.where(status: "pending").where(created_at: ..MessageHandoff::EXPIRY.ago), &:settle_lapsed!)
  end

  private

  def each_isolated(scope)
    scope.find_each do |record|
      yield record
    rescue StandardError => e
      Rails.logger.error "[MessageDispatchSweepJob] #{record.class.name} #{record.id}: #{e.class}: #{e.message}"
    end
  end

end
