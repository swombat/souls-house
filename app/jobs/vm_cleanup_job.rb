# Removes the server of a placement whose cleanup was requested (#246 slice
# 5), and keeps going until the provider confirms nothing is left:
#
#   * a purchase whose outcome is unknown keeps being reconciled; a server that
#     turns up is deleted
#   * a verified server is deleted, and deletion is reconciled until absent
#   * once every purchase is refused or deleted, the runner enrollment is
#     revoked and the placement retired, which releases its slot in the cap
#
# A purchase that needs review and never showed a server is left for an
# operator: nothing here can prove it bought nothing, so the placement stays
# counted against the cap. VmBirthSweepJob runs this every minute until the
# placement is retired; every run reads current state.
class VmCleanupJob < ApplicationJob

  queue_as :default

  LOCK_CLASS = 0x5646_434c

  def perform(placement_id)
    # Runs for one placement never overlap, so a delete is never sent twice
    # at once.
    ProvisionVmAgentJob.exclusively(placement_id, lock_class: LOCK_CLASS) { clean(placement_id) }
  end

  private

  def clean(placement_id)
    placement = AgentPlacement.find_by(id: placement_id)
    return if placement.nil? || !placement.cleanup_requested? || placement.state == "retired"

    procurement = ProvisionVmAgentJob.procurement_factory.call
    placement.cloud_procurement_operations.unresolved.order(:id).each { |operation| procurement.cleanup!(operation) }

    unresolved = placement.cloud_procurement_operations.unresolved.reload.to_a
    return retire!(placement) if unresolved.empty?

    if unresolved.all? { |operation| operation.state == "needs_review" && operation.provider_server_id.nil? }
      Rails.logger.warn("[vm_cleanup] placement=#{placement.id} needs an operator: " \
                        "#{unresolved.map { |o| "#{o.public_id}:#{o.review_reason}" }.join(', ')}")
    end
  rescue StandardError => e
    # Tried again by the next sweep.
    Rails.logger.error("[vm_cleanup] placement=#{placement_id} error, will retry: #{e.class}: #{e.message}")
  end

  def retire!(placement)
    placement.transaction do
      placement.lock!
      RunnerEnrollment.where(agent_placement_id: placement.id, revoked_at: nil).find_each(&:revoke!)
      placement.update!(state: "retired", provider_server_id: nil, location: nil)
    end
  end

end
