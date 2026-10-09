# Settles a VM resident's credential/service restart (#246 parity): waits for
# the runner's answer to that exact start command, then releases the turn
# hold and records the outcome (Agents::RemoteRuntime.settle_refresh!).
class RemoteRefreshSettleJob < ApplicationJob

  queue_as :default

  RECHECK_AFTER = 15.seconds

  def perform(placement_id)
    placement = AgentPlacement.find_by(id: placement_id)
    return unless placement&.refresh_command_id

    result = Agents::RemoteRuntime.settle_refresh!(placement)
    # :held waits for an answer or an operator; the per-minute sweep looks
    # again, so it isn't rescheduled tightly here.
    self.class.set(wait: RECHECK_AFTER).perform_later(placement.id) if %i[pending recovering].include?(result)
  end

end
