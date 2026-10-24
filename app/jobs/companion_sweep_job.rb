class CompanionSweepJob < ApplicationJob

  def perform
    now = Time.current
    # Keep the expiry predicate in each write. A concurrent rotation/enrollment
    # may replace the cache while this job waits for its row lock; PostgreSQL
    # then rechecks the predicate and preserves the new live recovery payload.
    # Keep previous-digest/request metadata for stale-use auditing, not recovery.
    CompanionDevice.where(session_retry_until: ..now).where.not(session_response: nil)
      .update_all(session_response: nil)
    CompanionEnrollmentGrant.where(enrollment_retry_until: ..now).where.not(enrollment_response: nil)
      .update_all(enrollment_response: nil)
    CompanionOperationBody.where(expires_at: ..now).delete_all
    CompanionOperationInput.where(expires_at: ..now).delete_all
  end

end
