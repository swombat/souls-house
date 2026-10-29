# A failed roll switches a resident off on purpose (ResidentSwitchedOffNotice).
# Repairing the runtime doesn't switch it back on: that is a separate step,
# and on 29 Oct it was missed, so Claude was up but off until Daniel noticed.
# This says so once per hold, in the hold's own conversation, when the
# resident's runtime has answered a health check since the hold but the
# resident is still inactive or paused. A resident switched back on is done.
class RollHoldWatchJob < ApplicationJob

  queue_as :default

  LOOKBACK = 30.days

  def perform
    reported = AuditLog.where(action: ResidentSwitchedOffNotice::STILL_OFF)
      .where(created_at: LOOKBACK.ago..).pluck(Arel.sql("data->>'hold_id'")).compact.map(&:to_i)
    AuditLog.where(action: ResidentSwitchedOffNotice::SWITCHED_OFF, auditable_type: "Agent")
      .where(created_at: LOOKBACK.ago..).where.not(id: reported).order(:id).find_each do |hold|
      agent = hold.auditable
      next unless agent
      # Only the latest hold per resident speaks; an older one is superseded.
      next if AuditLog.where(action: ResidentSwitchedOffNotice::SWITCHED_OFF, auditable: agent).where("id > ?", hold.id).exists?
      next if agent.active? && !agent.paused?
      next unless agent.health_state == "healthy" && agent.last_health_check_at && agent.last_health_check_at > hold.created_at

      ResidentSwitchedOffNotice.still_off!(hold)
    rescue StandardError => error
      Rails.logger.warn "[RollHoldWatch] hold #{hold.id}: #{error.class}: #{error.message}"
    end
  end

end
