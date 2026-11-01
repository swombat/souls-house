# Closes guest integration requests nobody answered (JWblqj). Pending grants
# nothing, so this is housekeeping on the home's list, not a boundary; the
# clock is the request's own requested_at, never updated_at, which
# provisioning touches. A stale approval is also refused at decision time
# (AgentServiceAccess#approve_home!), so nothing depends on this running first.
class GuestAccessRequestSweepJob < ApplicationJob

  queue_as :default

  def perform
    AgentServiceAccess.awaiting_home_approval
      .where(home_approval_requested_at: ..AgentServiceAccess::REQUEST_EXPIRY.ago)
      .find_each(&:expire_home!)
  end

end
