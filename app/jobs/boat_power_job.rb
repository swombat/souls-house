# Moves one Boat placement's power one step (BoatPower) and, while it is
# still settling or a wake is waiting, checks again later. One at a time per
# placement; BoatPower's compare-and-sets keep a stale run harmless anyway.
class BoatPowerJob < ApplicationJob

  queue_as :default
  limits_concurrency to: 1, key: ->(placement_id) { "boat_power_#{placement_id}" }, duration: 5.minutes

  def perform(placement_id)
    placement = AgentPlacement.find_by(id: placement_id)
    return if placement.nil? || !placement.boat?

    result = begin
      BoatPower.from_credentials.reconcile!(placement)
    rescue BoatClient::Error => e
      Rails.logger.warn("[BoatPowerJob] placement #{placement_id}: #{e.message}")
      BoatPower::Result.new(outcome: :error, retry_after: e.retry_after&.seconds)
    end
    return if result.outcome == :not_powered

    wait = recheck_after(placement.reload, result)
    self.class.set(wait:).perform_later(placement_id) if wait
  end

  private

  def recheck_after(placement, result)
    return nil unless placement.power_state == "waking" || placement.wake_pending?
    # A missing or failed box waits for an operator; clearing the review
    # starts the chain again.
    return nil if placement.power_review?
    return result.retry_after if result.retry_after

    BoatPower::RECHECK
  end

end
