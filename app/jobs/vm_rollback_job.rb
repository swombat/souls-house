# Drives one VmRollback (#426 3C rollback wiring) a phase at a time. While the
# server is still answering it polls; after a commit whose recreate or mount
# check failed it retries that step a bounded number of times, then leaves
# the attempt committed, with its error, for a person. It never reserves,
# never swaps twice and never releases the server.
class VmRollbackJob < ApplicationJob

  POLL = 30.seconds
  RECOVER_EVERY = 5.minutes
  RECOVER_TRIES = 6

  def perform(rollback_id, recover_tries = 0)
    rollback = VmRollback.find_by(id: rollback_id)
    return if rollback.nil? || !rollback.open?

    phase = Agents::VmMigration::Rollback.new(rollback).step!
    case phase
    when :busy, "stopping", "snapshotting"
      self.class.set(wait: POLL).perform_later(rollback_id, recover_tries)
    when "committed"
      self.class.set(wait: RECOVER_EVERY).perform_later(rollback_id, recover_tries + 1) if recover_tries < RECOVER_TRIES
    end
  end

end
