# The effects of one fulfilment of a watch, each recorded once it happens:
# the posted message (message_id) and each resident's wake (woken). The
# deliver job checks these before acting, so a retry after any partial
# success neither posts nor wakes twice. v1 keys by the watch (one-shot); a
# recurring watch would key by run id and attempt.
class RepositoryWatchDelivery < ApplicationRecord

  # The sweep retries an incomplete delivery (lost enqueue, or a job that
  # ran out of retries) with backoff until this many attempts, then it is
  # failed: the watch says so instead of going quiet.
  MAX_ATTEMPTS = 12

  belongs_to :repository_watch
  belongs_to :message, optional: true

  scope :incomplete, -> { where(completed_at: nil) }

  # Incomplete, not yet failed, and past its backoff (the same rule as
  # retry_due?), decided in SQL so a batch limit applies only to rows that
  # can actually be retried: failed rows can never fill a sweep's batch.
  scope :retry_due, ->(now = Time.current) {
    incomplete.where(attempts: ...MAX_ATTEMPTS)
      .where("updated_at <= ?::timestamp - (LEAST(POWER(2, LEAST(GREATEST(attempts, 1), 10)), 60) * INTERVAL '1 minute')", now)
  }

  def failed?
    !completed? && attempts >= MAX_ATTEMPTS
  end

  # Due for another try: 2, 4, 8 ... minutes after the last, at most an hour.
  def retry_due?(now = Time.current)
    !completed? && !failed? && updated_at <= now - [ (2**attempts.clamp(1, 10)).minutes, 1.hour ].min
  end

  def status
    return "delivered" if completed? && last_error.blank?
    return "refused" if completed?
    return "failed" if failed?

    "pending"
  end

  def woken?(agent_id)
    woken.to_h.key?(agent_id.to_s)
  end

  def completed?
    completed_at.present?
  end

end
